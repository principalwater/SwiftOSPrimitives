#if os(Linux)
  import NativeLinux
  import PageMemory
  import Synchronization
  #if canImport(Musl)
    import Musl
  #else
    import Glibc
  #endif

  private enum ProbeFailure: Error {
    case system(Int32)
    case framing, integrity, topology
  }
  private func emit(_ text: String) throws {
    let bytes = Array(text.utf8)
    var done = 0
    while done < bytes.count {
      let count = bytes.withUnsafeBytes { write(1, $0.baseAddress! + done, $0.count - done) }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { throw ProbeFailure.system(errno) }
      done += count
    }
  }
  private func command() throws -> String {
    var bytes: [UInt8] = []
    while bytes.count < 64 {
      var byte: UInt8 = 0
      let count = read(0, &byte, 1)
      if count < 0, errno == EINTR { continue }
      guard count == 1 else { throw ProbeFailure.framing }
      if byte == 10 { return String(decoding: bytes, as: UTF8.self) }
      guard byte >= 32, byte <= 126 else { throw ProbeFailure.framing }
      bytes.append(byte)
    }
    throw ProbeFailure.framing
  }
  private func memory() throws -> String {
    let fd = open("/proc/meminfo", O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { throw ProbeFailure.system(errno) }
    defer { _ = close(fd) }
    var bytes = [UInt8](repeating: 0, count: 8192)
    let count = read(fd, &bytes, bytes.count)
    guard count > 0, count < bytes.count else { throw ProbeFailure.system(errno) }
    let lines = String(decoding: bytes.prefix(count), as: UTF8.self).split(separator: "\n")
    func field(_ key: String) throws -> UInt64 {
      let selected = lines.filter { $0.hasPrefix(key + ":") }
      guard selected.count == 1 else { throw ProbeFailure.framing }
      let values = selected[0].split(whereSeparator: { $0 == " " || $0 == "\t" })
      guard values.count == 3, values[2] == "kB", let number = UInt64(values[1]), number < 1 << 40
      else { throw ProbeFailure.framing }
      return number * 1024
    }
    return "\(try field("MemTotal")) \(try field("MemAvailable"))"
  }
  private func loadState(cycle: Int) throws -> String {
    let fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0)
    guard fd >= 0 else { throw ProbeFailure.system(errno) }
    var owned = true
    defer { if owned { _ = close(fd) } }
    var timeout = timeval(tv_sec: 1, tv_usec: 0)
    for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
      guard setsockopt(fd, SOL_SOCKET, option, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0
      else { throw ProbeFailure.system(errno) }
    }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(8123).bigEndian
    address.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard connected == 0 else { throw ProbeFailure.system(errno) }
    let query =
      "SELECT count(), sum(memory_usage) FROM system.processes WHERE query_id = 'swiftos-load-\(cycle)' LIMIT 1 FORMAT TSVRaw"
    let request = Array(
      ("POST /?max_execution_time=2&max_threads=1 HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\nContent-Length: \(query.utf8.count)\r\n\r\n"
        + query).utf8)
    var sent = 0
    while sent < request.count {
      let count = request.withUnsafeBytes {
        send(fd, $0.baseAddress! + sent, $0.count - sent, Int32(MSG_NOSIGNAL))
      }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { throw ProbeFailure.system(errno) }
      sent += count
    }
    var response: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 512)
    var start = timespec()
    guard clock_gettime(CLOCK_MONOTONIC, &start) == 0 else { throw ProbeFailure.system(errno) }
    while response.count < 4096 {
      var now = timespec()
      guard clock_gettime(CLOCK_MONOTONIC, &now) == 0, now.tv_sec - start.tv_sec < 3
      else { throw ProbeFailure.framing }
      let count = recv(fd, &chunk, min(chunk.count, 4096 - response.count), 0)
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else { throw ProbeFailure.system(errno) }
      if count == 0 { break }
      response += chunk.prefix(count)
    }
    guard response.count < 4096, response.count >= 4,
      let boundary = (0...(response.count - 4)).first(where: {
        response[$0..<($0 + 4)].elementsEqual([13, 10, 13, 10])
      })
    else { throw ProbeFailure.framing }
    let header = String(decoding: response[..<boundary], as: UTF8.self)
    guard header.hasPrefix("HTTP/1.0 200 ") || header.hasPrefix("HTTP/1.1 200 "),
      !header.lowercased().contains("transfer-encoding:")
    else { throw ProbeFailure.framing }
    let fields = String(decoding: response[(boundary + 4)...], as: UTF8.self)
      .split(whereSeparator: { $0 == "\n" || $0 == "\t" })
    guard fields.count == 2, ["0", "1"].contains(fields[0]),
      let bytes = UInt64(fields[1]), bytes < 1 << 40
    else { throw ProbeFailure.framing }
    let closed = close(fd)
    owned = false
    guard closed == 0 else { throw ProbeFailure.system(errno) }
    return "\(fields[0]) \(bytes)"
  }
  private final class ProbeState: Sendable {
    struct Values {
      var stop = false
      var error = ""
      var work = [UInt64](repeating: 0, count: 4)
      var packets: UInt64 = 0
    }
    let values = Mutex(Values())
  }
  private final class CPUProbe: Sendable {
    let core: Int
    let network: Int
    let state: ProbeState
    init(core: Int, network: Int, state: ProbeState) {
      self.core = core
      self.network = network
      self.state = state
    }
    func run() {
      var descriptors: [Int32] = []
      do {
        var mask = cpu_set_t()
        withUnsafeMutableBytes(of: &mask) { bytes in
          bytes.initializeMemory(as: UInt8.self, repeating: 0)
          bytes[core / 8] = 1 << (core % 8)
        }
        guard sched_setaffinity(0, MemoryLayout<cpu_set_t>.size, &mask) == 0, sched_getcpu() == core
        else { throw ProbeFailure.topology }
        var region = try PageRegion.allocate(byteCount: 256 << 10)
        try region.withMutableBytes { bytes in
          for index in bytes.indices {
            bytes[index] = UInt8(truncatingIfNeeded: index &* 13 &+ core)
          }
        }
        for nic in 0..<network {
          let fd = socket(AF_INET, SOCK_DGRAM, 0)
          guard fd >= 0 else { throw ProbeFailure.system(errno) }
          descriptors.append(fd)
          var timeout = timeval(tv_sec: 1, tv_usec: 0)
          guard
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
              == 0
          else { throw ProbeFailure.system(errno) }
          var address = sockaddr_in()
          address.sin_family = sa_family_t(AF_INET)
          address.sin_port = UInt16(7070).bigEndian
          address.sin_addr.s_addr = UInt32(nic == 0 ? 0xc000_0201 : 0xc633_6401).bigEndian
          let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
              connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
          }
          guard result == 0 else { throw ProbeFailure.system(errno) }
        }
        var sequence: UInt64 = 0
        var outgoing = [UInt8](repeating: 0, count: 1024)
        var incoming = [UInt8](repeating: 0, count: 1024)
        while !state.values.withLock({ $0.stop }) {
          try region.withReadAccess { bytes in
            for index in bytes.indices {
              guard bytes[index] == UInt8(truncatingIfNeeded: index &* 13 &+ core) else {
                throw ProbeFailure.integrity
              }
            }
          }
          guard sched_getcpu() == core else { throw ProbeFailure.topology }
          for fd in descriptors {
            sequence += 1
            for index in outgoing.indices {
              outgoing[index] = UInt8(truncatingIfNeeded: UInt64(index) &* 7 &+ sequence)
            }
            outgoing.withUnsafeMutableBytes {
              $0.storeBytes(of: sequence.littleEndian, as: UInt64.self)
            }
            guard send(fd, &outgoing, outgoing.count, 0) == outgoing.count,
              recv(fd, &incoming, incoming.count, 0) == incoming.count,
              incoming == outgoing
            else { throw ProbeFailure.system(errno) }
          }
          state.values.withLock {
            $0.work[core] += 1
            $0.packets += UInt64(network)
          }
          usleep(10000)
        }
        try region.release()
      } catch {
        state.values.withLock {
          if $0.error.isEmpty { $0.error = String(describing: error) }
          $0.stop = true
        }
      }
      for fd in descriptors {
        if close(fd) != 0 { state.values.withLock { $0.error += " socket-close" } }
      }
    }
  }
  @main private struct Probe {
    static func main() {
      do { try run() } catch {
        try? emit("CANARY_FAIL \(error)\n")
        exit(1)
      }
    }
    static func run() throws {
      let args = Array(CommandLine.arguments.dropFirst())
      let cpus = Int(sysconf(Int32(_SC_NPROCESSORS_ONLN)))
      guard args.count == 2, Int(args[0]) == cpus, (1...4).contains(cpus),
        ["0", "1", "2"].contains(args[1])
      else { throw ProbeFailure.topology }
      let state = ProbeState()
      var workers: [pthread_t] = []
      var stopped = false
      func stop() throws {
        if stopped { return }
        state.values.withLock { $0.stop = true }
        var first: Int32 = 0
        for worker in workers {
          let code = pthread_join(worker, nil)
          if code != 0, first == 0 { first = code }
        }
        stopped = true
        guard first == 0 else { throw ProbeFailure.system(first) }
        let error = state.values.withLock { $0.error }
        guard error.isEmpty else { throw ProbeFailure.integrity }
      }
      do {
        for core in 0..<cpus {
          let context = Unmanaged.passRetained(
            CPUProbe(core: core, network: core == cpus - 1 ? Int(args[1])! : 0, state: state)
          ).toOpaque()
          var worker: pthread_t?
          let code = pthread_create(
            &worker, nil,
            { context in
              guard let context else { return nil }
              Unmanaged<CPUProbe>.fromOpaque(context).takeRetainedValue().run()
              return nil
            }, context)
          guard code == 0 else {
            Unmanaged<CPUProbe>.fromOpaque(context).release()
            throw ProbeFailure.system(code)
          }
          guard let worker else { throw ProbeFailure.framing }
          workers.append(worker)
        }
        for _ in 0..<300 {
          if state.values.withLock({
            !$0.error.isEmpty || $0.work.prefix(cpus).allSatisfy { $0 > 0 }
          }) {
            break
          }
          usleep(10000)
        }
        func summary() throws -> String {
          try state.values.withLock { values in
            guard values.error.isEmpty, values.work.prefix(cpus).allSatisfy({ $0 > 0 }) else {
              throw ProbeFailure.integrity
            }
            return "cpus=\(cpus) packets=\(values.packets) "
              + (0..<cpus).map { "cpu\($0)=\(values.work[$0])" }.joined(separator: " ")
          }
        }
        var region = try PageRegion.allocate(byteCount: 64 << 20)
        try region.withMutableBytes { bytes in
          for index in bytes.indices { bytes[index] = UInt8(truncatingIfNeeded: index &* 17 &+ 91) }
        }
        var pressure = try PageRegion.allocate(byteCount: 320 << 20, maximumMappedBytes: 320 << 20)
        var holding = false
        func checkPressure() throws {
          guard holding else { return }
          try pressure.withReadAccess { bytes in
            for index in bytes.indices {
              guard bytes[index] == UInt8(truncatingIfNeeded: index &* 31 &+ 47) else {
                throw ProbeFailure.integrity
              }
            }
          }
        }
        try emit("CANARY_READY \(try memory()) \(try summary())\n")
        for sequence in 1...64 {
          let text = try command()
          let fields = text.split(separator: " ")
          if fields.count == 3, fields[0] == "STATE", fields[1] == Substring(String(sequence)),
            let cycle = Int(fields[2]), (1...2).contains(cycle)
          {
            try emit("LOAD_STATE \(sequence) \(try loadState(cycle: cycle))\n")
            continue
          }
          if text == "HOLD \(sequence)" {
            guard !holding else { throw ProbeFailure.framing }
            try pressure.withMutableBytes { bytes in
              for index in bytes.indices {
                bytes[index] = UInt8(truncatingIfNeeded: index &* 31 &+ 47)
              }
            }
            holding = true
          } else if text == "DROP \(sequence)" {
            guard holding else { throw ProbeFailure.framing }
            try checkPressure()
            try pressure.release()
            pressure = try PageRegion.allocate(byteCount: 320 << 20, maximumMappedBytes: 320 << 20)
            holding = false
          } else {
            guard text == "VERIFY \(sequence)" || text == "QUIT \(sequence)" else {
              throw ProbeFailure.framing
            }
          }
          try checkPressure()
          try region.withReadAccess { bytes in
            for index in bytes.indices {
              guard bytes[index] == UInt8(truncatingIfNeeded: index &* 17 &+ 91) else {
                throw ProbeFailure.integrity
              }
            }
          }
          try emit("CANARY_OK \(sequence) \(try memory()) \(try summary())\n")
          if text.hasPrefix("QUIT") {
            try region.release()
            try pressure.release()
            try stop()
            return
          }
        }
        throw ProbeFailure.framing
      } catch {
        do { try stop() } catch { try? emit("CANARY_CLEANUP_FAIL \(error)\n") }
        throw error
      }
    }
  }
#else
  @main private struct Probe { static func main() { print("Linux probe only") } }
#endif
