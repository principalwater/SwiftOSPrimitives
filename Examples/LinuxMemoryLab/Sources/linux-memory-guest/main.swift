import PageMemory

#if os(Linux)
  import Musl
  import NativeLinux

  private enum GuestFailure: Error {
    case system(String, Int32)
    case protocolError, integrity, deadline
    case check(String)
  }
  private func require(_ result: Bool, _ label: String) throws {
    guard result else { throw GuestFailure.system(label, errno) }
  }
  private func emit(_ text: String) throws {
    try nativeWrite(1, Array((text + "\n").utf8))
  }
  private func command(_ expected: String) throws {
    var bytes: [UInt8] = []
    while bytes.count < 32 {
      var byte: UInt8 = 0
      let count = read(0, &byte, 1)
      if count < 0, errno == EINTR { continue }
      guard count == 1 else { throw GuestFailure.protocolError }
      if byte == 10 {
        guard String(decoding: bytes, as: UTF8.self) == expected else {
          throw GuestFailure.protocolError
        }
        return
      }
      guard byte >= 32 && byte < 127 else { throw GuestFailure.protocolError }
      bytes.append(byte)
    }
    throw GuestFailure.protocolError
  }

  private final class Workload {
    var server: NativeChild?
    var activeQuery: NativeChild?
    var loadQuery: NativeChild?
    var counter = 0
    var baseline = ""
    var canary: PageRegion
    init() throws { canary = try PageRegion.allocate(byteCount: 64 << 20) }
    let settings =
      " SETTINGS max_threads=1, max_memory_usage=201326592, max_rows_to_read=500000, max_bytes_to_read=100663296, max_execution_time=8, timeout_before_checking_execution_speed=0"

    func initialize() throws {
      try require(getpid() == 1 && geteuid() == 0, "pid1")
      var terminal = termios()
      try require(tcgetattr(0, &terminal) == 0, "terminal-get")
      cfmakeraw(&terminal)
      try require(tcsetattr(0, TCSANOW, &terminal) == 0, "terminal-set")
      try directory("/rootfs")
      try require(mount("/dev/vda", "/rootfs", "ext4", 0, nil) == 0, "rootfs-mount")
      try require(chdir("/rootfs") == 0 && chroot(".") == 0 && chdir("/") == 0, "chroot")
      for path in [
        "/proc", "/sys", "/dev", "/data", "/data/store", "/data/tmp", "/data/user_files", "/lab",
      ] {
        try directory(path)
      }
      for (kind, path) in [("proc", "/proc"), ("sysfs", "/sys"), ("devtmpfs", "/dev")] {
        try require(
          mount(kind, path, kind, UInt(kind == "devtmpfs" ? MS_NOSUID : MS_NOSUID | MS_NODEV), nil)
            == 0, "mount-" + kind)
      }
      let memmap = try readFile("/sys/module/memory_hotplug/parameters/memmap_on_memory")
      try require(memmap == "N", "memmap-on-memory-disabled")
      let zone = try readFile("/sys/devices/system/memory/memory32/valid_zones")
      try require(zone == "Movable", "movable-hotplug")
      try require(
        try readFile("/sys/devices/system/memory/memory32/state") == "online", "hotplug-online")
      let driver = try readFile("/sys/bus/virtio/devices/virtio0/device")
      try require(driver == "0x0018", "virtio-mem-device")
      try emit("LAB_PREFLIGHT memmap=N zone=Movable state=online virtio=0x0018")
      let socketFD = socket(AF_INET, Int32(SOCK_DGRAM), 0)
      try require(socketFD >= 0, "loopback-socket")
      defer { _ = Musl.close(socketFD) }
      var interface = ifreq()
      withUnsafeMutableBytes(of: &interface.ifr_ifrn.ifrn_name) {
        $0.copyBytes(from: Array("lo\0".utf8))
      }
      interface.ifr_ifru.ifru_flags = Int16(IFF_UP)
      try require(ioctl(socketFD, UInt(SIOCSIFFLAGS), &interface) == 0, "loopback-up")
      try writeFile("/lab/config.xml", Self.configuration)
      try writeFile("/lab/users.xml", Self.users)
      server = try launch(["server", "--config-file=/lab/config.xml"], label: "server")
      var ready = false
      for _ in 0..<20 {
        do { ready = try sql("SELECT 1 LIMIT 1" + settings) == "1" } catch { ready = false }
        if ready { break }
        try require(try server?.poll() == true, "server-exited")
        usleep(100000)
      }
      try require(ready, "sql-ready")
      _ = try sql(
        "CREATE TABLE default.ram_lab (id UInt64, payload String) ENGINE=MergeTree ORDER BY id")
      for batch in 0..<4 {
        _ = try sql(
          "INSERT INTO default.ram_lab SELECT number + \(batch * 100000), repeat(hex(cityHash64(number + \(batch * 100000))), 8) FROM numbers(100000)"
            + settings)
      }
      baseline = try integrity()
      try canary.withMutableBytes { bytes in
        for index in bytes.indices { bytes[index] = UInt8(truncatingIfNeeded: index &* 17 &+ 91) }
      }
      try verifyCanary()
      try emit(
        "CH_READY " + baseline.split(separator: "\t").joined(separator: " ")
          + " dynamicPages=\(try dynamicPages())")
    }
    func launch(_ arguments: [String], label: String) throws -> NativeChild {
      try NativeChild(arguments: arguments, path: "/data/" + label + ".log")
    }
    func finish(_ process: NativeChild, seconds: Int) throws {
      let deadline = try monotonic() + UInt64(seconds) * 1_000_000_000
      while try process.poll(), try monotonic() < deadline { usleep(10000) }
      guard try !process.poll() else {
        try process.signal(SIGKILL)
        try process.join(seconds: 2)
        throw GuestFailure.deadline
      }
      guard process.terminationStatus == 0 else {
        throw GuestFailure.system("child", process.terminationStatus)
      }
    }
    func sql(_ query: String) throws -> String {
      counter += 1
      let label = "query-\(counter)"
      let process = try launch(
        [
          "client", "--host", "127.0.0.1", "--port", "9000", "--format", "TSVRaw", "--query", query,
        ], label: label)
      activeQuery = process
      try finish(process, seconds: 12)
      activeQuery = nil
      return try readFile("/data/" + label + ".log")
    }
    func integrity() throws -> String {
      let value = try sql(
        "SELECT count(), sum(id), sum(cityHash64(payload)), sum(length(payload)) FROM default.ram_lab WHERE id < 400000 LIMIT 1"
          + settings)
      let fields = value.split(separator: "\t")
      guard fields.count == 4, fields[0] == "400000", fields[1] == "79999800000",
        UInt64(fields[2]) != nil, UInt64(fields[3]) != nil
      else {
        throw GuestFailure.integrity
      }
      return value
    }
    func verifyCanary() throws {
      try canary.withReadAccess { bytes in
        for index in bytes.indices {
          guard bytes[index] == UInt8(truncatingIfNeeded: index &* 17 &+ 91) else {
            throw GuestFailure.check("canary-index=\(index)")
          }
        }
      }
    }
    func dynamicPages() throws -> Int {
      let descriptor = open("/proc/self/pagemap", O_RDONLY | O_CLOEXEC)
      try require(descriptor >= 0, "pagemap-open")
      defer { _ = Musl.close(descriptor) }
      return try canary.withReadAccess { bytes in
        let address = bytes.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress!) }
        let count = bytes.count / 4096
        return try withUnsafeTemporaryAllocation(of: UInt64.self, capacity: count) { entries in
          let length = count * 8
          try require(
            pread(descriptor, entries.baseAddress!, length, off_t(address / 4096 * 8)) == length,
            "pagemap-read")
          return entries.reduce(0) { total, entry in
            let gpa = (entry & ((1 << 55) - 1)) * 4096
            return total
              + (entry & (1 << 63) != 0 && gpa >= 0x1_0000_0000 && gpa < 0x1_0800_0000 ? 1 : 0)
          }
        }
      }
    }
    func load(_ sequence: Int) throws {
      counter += 1
      let identity = "ram-load-\(sequence)"
      loadQuery = try launch(
        [
          "client", "--host", "127.0.0.1", "--query_id", identity, "--query",
          "SELECT sum(length(payload) + sleepEachRow(0.000005)) FROM (SELECT id, any(payload) AS payload FROM default.ram_lab WHERE id < 400000 GROUP BY id) LIMIT 1"
            + settings,
        ], label: "load-\(sequence)")
      var observed: UInt64 = 0
      for _ in 0..<20 {
        guard try loadQuery?.poll() == true else { throw GuestFailure.integrity }
        let state = try sql(
          "SELECT count(), sum(memory_usage) FROM system.processes WHERE query_id = '" + identity
            + "' LIMIT 1" + settings
        ).split(separator: "\t")
        guard state.count == 2, let memory = UInt64(state[1]) else {
          throw GuestFailure.protocolError
        }
        if state[0] == "1", memory >= 16 << 20 {
          observed = memory
          break
        }
        usleep(25000)
      }
      guard observed >= 16 << 20 else { throw GuestFailure.integrity }
      try emit("CH_LOAD_RUNNING \(sequence) memoryBytes=\(observed)")
    }
    func verify(_ sequence: Int) throws {
      guard let query = loadQuery else { throw GuestFailure.protocolError }
      try finish(query, seconds: 12)
      loadQuery = nil
      let loadResult = try readFile("/data/load-\(sequence).log")
      let payloadBytes = baseline.split(separator: "\t").last!
      guard loadResult == payloadBytes else {
        throw GuestFailure.check("load-result=\(loadResult) expected=\(payloadBytes)")
      }
      try verifyCanary()
      let after = try integrity()
      let pages = try dynamicPages()
      guard after == baseline, pages == 0, try server?.poll() == true else {
        throw GuestFailure.check("post=\(after) before=\(baseline) dynamicPages=\(pages)")
      }
      try emit("CH_SHRUNK \(sequence) dataOK=1 canaryOK=1 dynamicPages=0")
    }
    func close() -> [String] {
      var errors: [String] = []
      for process in [activeQuery, loadQuery, server].compactMap({ $0 }) {
        do {
          if try process.poll() {
            try process.signal(SIGTERM)
            do { try process.join(seconds: 5) } catch {
              try process.signal(SIGKILL)
              try process.join(seconds: 2)
            }
          }
          if process.terminationStatus != 0 {
            errors.append("child-exit-\(process.terminationStatus)")
          }
        } catch { errors.append("child-cleanup-\(error)") }
      }
      var status: Int32 = 0
      let residual = waitpid(-1, &status, WNOHANG)
      if residual != -1 || errno != ECHILD { errors.append("unreaped-child-\(residual)") }
      sync()
      return errors
    }
    static let configuration = """
      <clickhouse><logger><level>warning</level><log>/data/server.log</log><errorlog>/data/server.err.log</errorlog><size>1M</size><count>1</count></logger>
      <path>/data/store/</path><tmp_path>/data/tmp/</tmp_path><user_files_path>/data/user_files/</user_files_path><users_config>/lab/users.xml</users_config>
      <listen_host>127.0.0.1</listen_host><tcp_port>9000</tcp_port><max_server_memory_usage>671088640</max_server_memory_usage>
      <max_thread_pool_size>64</max_thread_pool_size><background_pool_size>2</background_pool_size><background_schedule_pool_size>2</background_schedule_pool_size>
      <background_streaming_schedule_pool_size>1</background_streaming_schedule_pool_size><background_move_pool_size>1</background_move_pool_size><background_fetches_pool_size>1</background_fetches_pool_size><background_common_pool_size>1</background_common_pool_size>
      <background_message_broker_schedule_pool_size>1</background_message_broker_schedule_pool_size><background_distributed_schedule_pool_size>1</background_distributed_schedule_pool_size><background_buffer_flush_schedule_pool_size>1</background_buffer_flush_schedule_pool_size>
      <merge_tree><number_of_free_entries_in_pool_to_execute_mutation>0</number_of_free_entries_in_pool_to_execute_mutation><number_of_free_entries_in_pool_to_lower_max_size_of_merge>0</number_of_free_entries_in_pool_to_lower_max_size_of_merge><number_of_free_entries_in_pool_to_execute_optimize_entire_partition>0</number_of_free_entries_in_pool_to_execute_optimize_entire_partition></merge_tree>
      <mark_cache_size>8388608</mark_cache_size><uncompressed_cache_size>8388608</uncompressed_cache_size><mlock_executable>false</mlock_executable>
      </clickhouse>
      """
    static let users = """
      <clickhouse><profiles><default><max_memory_usage>201326592</max_memory_usage><max_threads>1</max_threads><max_execution_time>8</max_execution_time><timeout_before_checking_execution_speed>0</timeout_before_checking_execution_speed><max_rows_to_read>500000</max_rows_to_read><max_bytes_to_read>100663296</max_bytes_to_read><max_result_rows>1000</max_result_rows></default></profiles><users><default><password></password><profile>default</profile><quota>default</quota><networks><ip>127.0.0.1</ip></networks></default></users><quotas><default><interval><duration>3600</duration><queries>100</queries><errors>30</errors><result_rows>10000</result_rows><read_rows>20000000</read_rows><execution_time>120</execution_time></interval></default></quotas></clickhouse>
      """
  }

  @main private struct Guest {
    static func main() {
      do { try run() } catch { try? emit("CH_FAIL initial=\(error)") }
      while true { _ = pause() }
    }
    private static func run() throws {
      let workload = try Workload()
      var primary = ""
      do {
        try workload.initialize()
        try command("L 1")
        try workload.load(1)
        try command("V 1")
        try workload.verify(1)
        try command("G 2")
        try workload.verifyCanary()
        try workload.load(2)
        try command("V 2")
        try workload.verify(2)
      } catch { primary = String(describing: error) }
      let cleanup = workload.close()
      if primary.isEmpty, cleanup.isEmpty {
        try? emit("CH_DONE")
      } else {
        try? emit("CH_FAIL \(primary) cleanup=\(cleanup)")
      }
      while true { _ = pause() }
    }
  }
#else
  @main private struct Guest { static func main() { print("Linux guest only") } }
#endif
