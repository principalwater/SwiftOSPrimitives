import PageMemory

#if canImport(Musl)
  import Musl
#else
  import Glibc
#endif

private enum Failure: Error { case system, framing, memory, sequence }

private func send(_ text: String) throws {
  try text.utf8.withContiguousStorageIfAvailable { bytes in
    var offset = 0
    while offset < bytes.count {
      let count = write(STDOUT_FILENO, bytes.baseAddress! + offset, bytes.count - offset)
      if count < 0 && errno == EINTR { continue }
      guard count > 0 else { throw Failure.system }
      offset += count
    }
  } ?? { throw Failure.framing }()
}

private func readFile(_ path: String) throws -> String {
  let fd = open(path, O_RDONLY | O_CLOEXEC)
  guard fd >= 0 else { throw Failure.system }
  defer { _ = close(fd) }
  return try withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 8193) { bytes in
    var count = 0
    while count < bytes.count {
      let next = read(fd, bytes.baseAddress! + count, bytes.count - count)
      if next < 0 && errno == EINTR { continue }
      guard next >= 0 else { throw Failure.system }
      if next == 0 { break }
      count += next
    }
    guard count <= 8192 else { throw Failure.framing }
    return String(
      decoding: UnsafeBufferPointer(start: bytes.baseAddress, count: count), as: UTF8.self)
  }
}

private func memory() throws -> (total: UInt64, available: UInt64) {
  let text = try readFile("/proc/meminfo")
  func field(_ key: String) throws -> UInt64 {
    let lines = text.split(separator: "\n").filter { $0.hasPrefix(key + ":") }
    guard lines.count == 1 else { throw Failure.framing }
    let words = lines[0].split(whereSeparator: { $0 == " " || $0 == "\t" })
    guard words.count == 3, words[2] == "kB", let value = UInt64(words[1]),
      value <= UInt64.max / 1024
    else { throw Failure.framing }
    return value * 1024
  }
  return (try field("MemTotal"), try field("MemAvailable"))
}

private func driverState() throws -> String {
  guard let directory = opendir("/sys/bus/virtio/devices") else { throw Failure.system }
  defer { _ = closedir(directory) }
  var state = "none"
  var count = 0
  while let entry = readdir(directory) {
    count += 1
    guard count <= 64 else { throw Failure.framing }
    let name = withUnsafePointer(to: entry.pointee.d_name) {
      $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
    }
    guard !name.hasPrefix(".") else { continue }
    let path = "/sys/bus/virtio/devices/" + name
    let identity = try readFile(path + "/device").split(separator: "\n")
    guard identity.count == 1 else { throw Failure.framing }
    guard identity[0] == "0x0005" else { continue }
    guard state == "none" else { throw Failure.system }
    if access(path + "/driver", F_OK) == 0 {
      var link = [CChar](repeating: 0, count: 256)
      let length = readlink(path + "/driver", &link, link.count - 1)
      guard length > 0, length < link.count - 1,
        String(decoding: link.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
          .hasSuffix("/virtio_balloon")
      else { throw Failure.system }
      let features = try readFile(path + "/features").split(separator: "\n")
      guard features.count == 1, features[0].count >= 64, features[0].count <= 256,
        features[0].allSatisfy({ $0 == "0" || $0 == "1" })
      else { throw Failure.framing }
      state = "bound:" + features[0]
    } else {
      guard errno == ENOENT else { throw Failure.system }
      state = "unbound"
    }
  }
  return state
}

private func matches(_ bytes: Span<UInt8>, _ value: UInt8) -> Bool {
  for index in bytes.indices { if bytes[index] != value { return false } }
  return true
}

private func command() throws -> String {
  var text = ""
  while text.utf8.count < 64 {
    var byte: UInt8 = 0
    let count = read(STDIN_FILENO, &byte, 1)
    if count < 0 && errno == EINTR { continue }
    guard count == 1, byte == 10 || byte >= 32 && byte <= 126 else { throw Failure.framing }
    if byte == 10 { return text }
    text.append(Character(UnicodeScalar(byte)))
  }
  throw Failure.framing
}

@main private struct Guest {
  private enum Mode { case boot, agent, workload }

  static func main() {
    do {
      let arguments = Array(CommandLine.arguments.dropFirst())
      let mode: Mode
      switch arguments {
      case []: mode = .boot
      case ["--agent"]: mode = .agent
      case ["--workload"]: mode = .workload
      default: throw Failure.framing
      }
      try run(mode: mode)
    } catch {
      try? send("PROBE_FAIL \(error)\n")
      if CommandLine.arguments.count == 1 {
        while true { _ = pause() }
      }
      exit(1)
    }
  }

  private static func run(mode: Mode) throws {
    if mode == .boot {
      guard getpid() == 1 else { throw Failure.system }
      // Boot PID1 inherits a terminal; agent/container modes use pipe/vsock streams.
      var terminal = termios()
      guard tcgetattr(STDIN_FILENO, &terminal) == 0 else { throw Failure.system }
      cfmakeraw(&terminal)
      guard tcsetattr(STDIN_FILENO, TCSANOW, &terminal) == 0 else { throw Failure.system }
    } else if mode == .agent {
      guard getpid() > 1, geteuid() == 0 else { throw Failure.system }
    }
    let byteCount = mode == .agent ? 4096 : (mode == .workload ? 88 : 64) * 1024 * 1024
    var region = try PageRegion.allocate(
      byteCount: byteCount, maximumMappedBytes: byteCount, backing: .reclaimable)
    var canary = try PageRegion.allocate(byteCount: 8 * 1024 * 1024)
    try canary.withMutableBytes { bytes in
      for index in bytes.indices { bytes[index] = 0x3c }
    }
    let balloon: BalloonState?
    if mode == .workload { balloon = nil } else { balloon = try BalloonState() }
    let before = try memory()
    let driver = mode == .workload ? "workload" : try driverState()
    try send(
      "PROBE_READY \(region.pageSize) \(before.total) \(before.available) \(driver)\n")
    var previous: UInt64 = 0
    for _ in 0..<1000 {
      let words = try command().split(separator: " ")
      guard words.count == 2, let sequence = UInt64(words[1]), sequence == previous + 1 else {
        throw Failure.sequence
      }
      previous = sequence
      guard try canary.withBytes({ matches($0, 0x3c) }) else { throw Failure.memory }
      switch words[0] {
      case "I":
        guard mode == .workload else { throw Failure.framing }
        let limit = try readFile("/sys/fs/cgroup/memory.max").split(separator: "\n")
        guard limit.count == 1, let maximum = UInt64(limit[0]) else { throw Failure.framing }
        let status = try readFile("/proc/self/status").split(separator: "\n")
        func statusField(_ key: String) throws -> Substring {
          let lines = status.filter { $0.hasPrefix(key + ":") }
          guard lines.count == 1 else { throw Failure.framing }
          let fields = lines[0].split(whereSeparator: { $0 == " " || $0 == "\t" })
          guard fields.count == 2 else { throw Failure.framing }
          return fields[1]
        }
        let capabilities = try statusField("CapEff")
        let noNewPrivileges = try statusField("NoNewPrivs")
        var filesystem = statvfs()
        guard statvfs("/probe", &filesystem) == 0 else { throw Failure.system }
        let readOnly = UInt64(filesystem.f_flag) & UInt64(ST_RDONLY) != 0
        let executable = open("/probe/probe", O_WRONLY | O_CLOEXEC)
        if executable >= 0 {
          _ = close(executable)
        } else {
          // An executing inode can refuse with ETXTBSY before the mount's EROFS check.
          guard errno == EROFS || errno == ETXTBSY else { throw Failure.system }
        }
        let mem = open("/dev/mem", O_RDONLY | O_CLOEXEC)
        if mem >= 0 {
          _ = close(mem)
        } else {
          guard errno == ENOENT || errno == EACCES || errno == EPERM else { throw Failure.system }
        }
        try send(
          "PROBE_INFO \(sequence) \(maximum) \(capabilities) \(noNewPrivileges) \(executable >= 0 || !readOnly ? 1 : 0) \(mem >= 0 ? 1 : 0)\n"
        )
        continue
      case "S": break
      case "T":
        guard mode != .agent else { throw Failure.framing }
        guard try memory().available >= 96 * 1024 * 1024 else { throw Failure.memory }
        try region.resetToZero()
        let zero = try region.withBytes { matches($0, 0) }
        guard zero else { throw Failure.memory }
        try region.withMutableBytes { bytes in
          for index in bytes.indices { bytes[index] = 0xa5 }
        }
        let initialized = try region.withBytes { matches($0, 0xa5) }
        guard initialized,
          try region.residentPageCount() == region.mappedByteCount / region.pageSize
        else { throw Failure.memory }
      case "E":
        guard mode != .agent else { throw Failure.framing }
        try region.eraseContents()
        let erased = try region.withBytes { matches($0, 0) }
        guard erased else { throw Failure.memory }
        _ = try region.discardContents()
        guard try region.residentPageCount() == 0 else { throw Failure.memory }
      case "Q":
        guard mode != .boot else { throw Failure.framing }
        try region.eraseContents()
        guard try region.withBytes({ matches($0, 0) }) else { throw Failure.memory }
        _ = try region.discardContents()
        try canary.eraseContents()
        guard try canary.withBytes({ matches($0, 0) }) else { throw Failure.memory }
        try send("PROBE_DONE \(sequence)\n")
        return
      default: throw Failure.framing
      }
      let current = try memory()
      let own = try ProcessMemorySnapshot.capture()
      let state = try balloon?.observe()
      try send(
        "PROBE_OBS \(sequence) \(current.total) \(current.available) \(try region.residentPageCount()) \(own.residentBytes) \(state?.requested ?? UInt32.max) \(state?.actual ?? UInt32.max)\n"
      )
    }
    throw Failure.framing
  }
}
