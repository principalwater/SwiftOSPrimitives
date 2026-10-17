#if os(Linux)
  import LabHTTP
  import MemoryCanary
  import NativeGuestMemory
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
    case framing, integrity, topology, loadTimedOut
    case capacityTimedOut(total: UInt64, minimum: UInt64, elapsedNanoseconds: UInt64)
    case execution(Int32)
  }
  private func localSQL(
    _ query: String, queryID: String? = nil, executionSeconds: Int = 8, receiveSeconds: Int = 10
  ) throws -> String {
    guard !query.isEmpty, query.utf8.count <= 4096,
      executionSeconds == 2 && receiveSeconds == 3
        || executionSeconds == 8 && receiveSeconds == 10,
      queryID.map({ !$0.isEmpty && $0.utf8.count <= 128
        && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0)
          || (97...122).contains($0) || [45, 46, 95].contains($0) } }) ?? true
    else { throw ProbeFailure.framing }
    let fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0)
    guard fd >= 0 else { throw ProbeFailure.system(errno) }
    var owned = true
    defer { if owned { _ = close(fd) } }
    var timeout = timeval(tv_sec: executionSeconds == 2 ? 1 : 2, tv_usec: 0)
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
    var options = "max_execution_time=\(executionSeconds)&max_threads=1"
      + "&max_memory_usage=201326592&timeout_before_checking_execution_speed=0"
      + "&max_rows_to_read=500000&max_bytes_to_read=100663296&max_result_rows=1000"
      + "&default_format=TSVRaw&wait_end_of_query=1&buffer_size=4096"
    if let queryID { options += "&query_id=" + queryID }
    let request = Array(
      ("POST /?\(options) HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n"
        + "Content-Length: \(query.utf8.count)\r\n\r\n" + query).utf8)
    timeout = timeval(tv_sec: 3, tv_usec: 0)
    guard setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      == 0 else { throw ProbeFailure.system(errno) }
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
      guard clock_gettime(CLOCK_MONOTONIC, &now) == 0, now.tv_sec >= start.tv_sec,
        now.tv_sec - start.tv_sec <= receiveSeconds
      else { throw ProbeFailure.loadTimedOut }
      let elapsed = (now.tv_sec - start.tv_sec) * 1_000_000_000 + now.tv_nsec - start.tv_nsec
      guard elapsed >= 0, elapsed < receiveSeconds * 1_000_000_000 else {
        throw ProbeFailure.loadTimedOut
      }
      let micros = min(1_000_000, (receiveSeconds * 1_000_000_000 - elapsed + 999) / 1000)
      var remaining = timeval(tv_sec: micros / 1_000_000, tv_usec: micros % 1_000_000)
      guard
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &remaining, socklen_t(MemoryLayout<timeval>.size))
          == 0
      else { throw ProbeFailure.system(errno) }
      let count = recv(fd, &chunk, min(chunk.count, 4096 - response.count), 0)
      // Retry only inside this transaction's original bounded receive deadline.
      if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
      guard count >= 0 else { throw ProbeFailure.system(errno) }
      if count == 0 { break }
      response += chunk.prefix(count)
    }
    let body = try LabHTTPResponse.body(response)
    let closed = close(fd)
    owned = false
    guard closed == 0 else { throw ProbeFailure.system(errno) }
    return body
  }
  private func loadState(cycle: Int) throws -> String {
    let query =
      "SELECT count(), sum(memory_usage) FROM system.processes WHERE query_id = 'swiftos-load-\(cycle)' LIMIT 1 FORMAT TSVRaw"
    let fields = try localSQL(query, executionSeconds: 2, receiveSeconds: 3)
      .split(whereSeparator: { $0 == "\n" || $0 == "\t" })
    guard fields.count == 2, ["0", "1"].contains(fields[0]),
      let bytes = UInt64(fields[1]), bytes < 1 << 40
    else { throw ProbeFailure.framing }
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
        try? GuestWire.emit("CANARY_FAIL \(error)\n")
        exit(1)
      }
    }
    static func run() throws {
      let args = Array(CommandLine.arguments.dropFirst())
      if args.first == "--wait-capacity-exec" { try launchAfterCapacity(args) }
      if args.first == "--http-query" {
        guard (2...3).contains(args.count) else { throw ProbeFailure.framing }
        try GuestWire.emit(try localSQL(args[1], queryID: args.count == 3 ? args[2] : nil))
        return
      }
      if args == ["--memory-monitor"] {
        try GuestMemoryMonitor.run()
        return
      }
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
        var checkedWork = [UInt64](repeating: 0, count: cpus)
        var checkedPackets: UInt64 = 0
        func summary(progress: Bool = true) throws -> String {
          var began = timespec()
          guard clock_gettime(CLOCK_MONOTONIC, &began) == 0 else {
            throw ProbeFailure.system(errno)
          }
          while true {
            var now = timespec()
            guard clock_gettime(CLOCK_MONOTONIC, &now) == 0, now.tv_sec >= began.tv_sec,
              now.tv_sec - began.tv_sec <= 1
            else { throw ProbeFailure.integrity }
            let elapsed = (now.tv_sec - began.tv_sec) * 1_000_000_000 + now.tv_nsec - began.tv_nsec
            guard elapsed >= 0, elapsed < 1_000_000_000 else { throw ProbeFailure.integrity }
            let values = state.values.withLock { $0 }
            guard values.error.isEmpty, values.work.prefix(cpus).allSatisfy({ $0 > 0 }) else {
              throw ProbeFailure.integrity
            }
            if !progress
              || (0..<cpus).allSatisfy({ values.work[$0] > checkedWork[$0] })
                && (args[1] == "0" || values.packets > checkedPackets)
            {
              if progress {
                checkedWork = Array(values.work.prefix(cpus))
                checkedPackets = values.packets
              }
              return "cpus=\(cpus) packets=\(values.packets) "
                + (0..<cpus).map { "cpu\($0)=\(values.work[$0])" }.joined(separator: " ")
            }
            // Fast memory checks can finish before a real10ms worker beacon.
            usleep(1000)
          }
        }
        var region = try PageRegion.allocate(byteCount: 64 << 20)
        try region.withMutableBytes { bytes in
          MemoryCanary.fill(&bytes, multiplier: 17, seed: 91)
        }
        var pressure = try PageRegion.allocate(byteCount: 320 << 20, maximumMappedBytes: 320 << 20)
        var holding = false
        func checkPressure() throws {
          guard holding else { return }
          try pressure.withReadAccess { bytes in
            try MemoryCanary.check(bytes, multiplier: 31, seed: 47)
          }
        }
        try GuestWire.emit(
          "CANARY_READY \(try GuestMemory.snapshot().wireFields) \(try summary())\n")
        var sequence: UInt64 = 0
        while sequence < UInt64.max {
          sequence += 1
          guard let text = try GuestWire.nextCommand() else { throw ProbeFailure.framing }
          let fields = text.split(separator: " ")
          if fields.count == 3, fields[0] == "STATE", fields[1] == Substring(String(sequence)),
            let cycle = Int(fields[2]), (1...2).contains(cycle)
          {
            try GuestWire.emit("LOAD_STATE \(sequence) \(try loadState(cycle: cycle))\n")
            continue
          }
          if text == "HOLD \(sequence)" {
            guard !holding else { throw ProbeFailure.framing }
            try pressure.withMutableBytes { bytes in
              MemoryCanary.fill(&bytes, multiplier: 31, seed: 47)
            }
            holding = true
          } else if text == "DROP \(sequence)" {
            guard holding else { throw ProbeFailure.framing }
            try checkPressure()
            try pressure.release()
            pressure = try PageRegion.allocate(byteCount: 320 << 20, maximumMappedBytes: 320 << 20)
            holding = false
          } else if text == "QUIESCE \(sequence)" {
            guard !stopped else { throw ProbeFailure.framing }
            try stop()
          } else {
            guard
              text == "VERIFY \(sequence)" || text == "OBS \(sequence)"
                || text == "OBS_REFRESH \(sequence)" || text == "QUIT \(sequence)"
            else {
              throw ProbeFailure.framing
            }
          }
          let passive = text.hasPrefix("OBS ") || text.hasPrefix("OBS_REFRESH ")
          if text.hasPrefix("OBS_REFRESH ") { try GuestMemory.refreshStatistics() }
          if !passive {
            try checkPressure()
            try region.withReadAccess { bytes in
              try MemoryCanary.check(bytes, multiplier: 17, seed: 91)
            }
          }
          let reading = try GuestMemory.snapshot()
          try GuestWire.emit(
            "CANARY_OK \(sequence) \(reading.wireFields) "
              + "\(try summary(progress: !passive && !stopped))\n")
          if text.hasPrefix("QUIT") {
            try region.release()
            try pressure.release()
            try stop()
            return
          }
        }
        throw ProbeFailure.framing
      } catch {
        do { try stop() } catch { try? GuestWire.emit("CANARY_CLEANUP_FAIL \(error)\n") }
        throw error
      }
    }

    private static func launchAfterCapacity(_ args: [String]) throws -> Never {
      guard (3...32).contains(args.count), let minimum = UInt64(args[1]),
        ((128 << 20)...(3 << 30)).contains(minimum), args[2].hasPrefix("/"),
        args.allSatisfy({ !$0.utf8.contains(0) }),
        args.reduce(0, { $0 + $1.utf8.count }) <= 4096
      else { throw ProbeFailure.framing }
      var began = timespec()
      guard clock_gettime(CLOCK_MONOTONIC, &began) == 0 else {
        throw ProbeFailure.system(errno)
      }
      while true {
        var now = timespec()
        let total = try GuestMemory.snapshot().total
        // A blocked proc read cannot publish a capacity receipt after its deadline.
        guard clock_gettime(CLOCK_MONOTONIC, &now) == 0, now.tv_sec >= began.tv_sec,
          now.tv_sec - began.tv_sec < Int64.max / 1_000_000_000
        else { throw ProbeFailure.framing }
        let elapsed = (now.tv_sec - began.tv_sec) * 1_000_000_000 + now.tv_nsec - began.tv_nsec
        guard elapsed >= 0 else { throw ProbeFailure.framing }
        guard elapsed < 8_000_000_000 else {
          throw ProbeFailure.capacityTimedOut(
            total: total, minimum: minimum, elapsedNanoseconds: UInt64(elapsed))
        }
        if total >= minimum {
          try GuestWire.emit("CAPACITY_READY \(total) \(elapsed)\n")
          break
        }
        usleep(10000)
      }
      // execv replaces this Swift process and its pages; no waiting shell or extra daemon remains.
      let strings = args.dropFirst(2).map { strdup($0) }
      defer { for string in strings { free(string) } }
      guard strings.allSatisfy({ $0 != nil }) else { throw ProbeFailure.system(ENOMEM) }
      var arguments = strings + [nil]
      _ = arguments.withUnsafeMutableBufferPointer { execv(strings[0]!, $0.baseAddress!) }
      throw ProbeFailure.execution(errno)
    }
  }
#else
  @main private struct Probe { static func main() { print("Linux probe only") } }
#endif
