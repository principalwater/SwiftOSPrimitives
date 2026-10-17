#if os(Linux)
  #if canImport(Musl)
    import Musl
  #else
    import Glibc
  #endif
#endif

/// Failure of guest memory observation; `framing` covers every malformed proc or wire input.
public enum GuestMemoryFailure: Error, Equatable, Sendable {
  case system(Int32)
  case framing
}

/// A validated `/proc/meminfo` snapshot in bytes with `total > 0` and `available <= total`.
public struct GuestMemoryReading: Equatable, Sendable {
  public let total: UInt64
  public let available: UInt64

  /// The `<total> <available>` fields shared by every memory wire frame.
  public var wireFields: String { "\(total) \(available)" }
}

/// One request of the memory monitor wire; the sequence number must match exactly.
enum MemoryMonitorCommand: Equatable {
  case observe, observeRefreshing, quit

  init?(line: String, sequence: UInt64) {
    switch line {
    case "OBS \(sequence)": self = .observe
    case "OBS_REFRESH \(sequence)": self = .observeRefreshing
    case "QUIT \(sequence)": self = .quit
    default: return nil
    }
  }
}

/// Bounded observation of guest memory through procfs; it reports and refreshes, never releases.
public enum GuestMemory {
  /// A larger meminfo is refused instead of being truncated.
  static let meminfoLimit = 8192

  /// Parses exactly one `MemTotal:` and one `MemAvailable:` line, each `<digits> kB`.
  static func parse(meminfo bytes: UnsafeBufferPointer<UInt8>) throws -> GuestMemoryReading {
    let total = try kilobytes("MemTotal:", in: bytes)
    let available = try kilobytes("MemAvailable:", in: bytes)
    guard total > 0, available <= total else { throw GuestMemoryFailure.framing }
    return GuestMemoryReading(total: total, available: available)
  }

  private static func isBlank(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 }

  private static func kilobytes(_ key: String, in bytes: UnsafeBufferPointer<UInt8>) throws
    -> UInt64
  {
    var found: UInt64?
    var start = 0
    while start < bytes.count {
      var end = start
      while end < bytes.count, bytes[end] != 10 { end += 1 }
      let line = UnsafeBufferPointer(rebasing: bytes[start..<end])
      if line.starts(with: key.utf8) {
        guard found == nil else { throw GuestMemoryFailure.framing }
        found = try kilobytes(line: line, afterKey: key.utf8.count)
      }
      start = end + 1
    }
    guard let found else { throw GuestMemoryFailure.framing }
    return found
  }

  /// Accepts `<blanks><digits><blanks>kB<blanks>`; values of 2^40 kB or more are refused.
  private static func kilobytes(line: UnsafeBufferPointer<UInt8>, afterKey keyLength: Int) throws
    -> UInt64
  {
    var index = keyLength
    func skipBlanks() -> Bool {
      let first = index
      while index < line.count, isBlank(line[index]) { index += 1 }
      return index > first
    }
    guard skipBlanks() else { throw GuestMemoryFailure.framing }
    let digits = index
    var value: UInt64 = 0
    while index < line.count, (48...57).contains(line[index]) {
      value = value * 10 + UInt64(line[index] - 48)
      guard value < 1 << 40 else { throw GuestMemoryFailure.framing }
      index += 1
    }
    guard index > digits, skipBlanks(), line.count - index >= 2, line[index] == 0x6b,
      line[index + 1] == 0x42
    else { throw GuestMemoryFailure.framing }
    index += 2
    _ = skipBlanks()
    guard index == line.count else { throw GuestMemoryFailure.framing }
    return value * 1024
  }
}

#if os(Linux)
  extension GuestMemory {
    /// Reads and validates `/proc/meminfo` into a stack buffer of at most `meminfoLimit` bytes.
    public static func snapshot() throws -> GuestMemoryReading {
      try withProcBytes(at: "/proc/meminfo", parse)
    }

    /// Internal procfs inputs share the same bounded read and checked descriptor lifetime.
    static func withProcBytes<Value>(
      at path: String, _ consume: (UnsafeBufferPointer<UInt8>) throws -> Value
    ) throws -> Value {
      let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
      guard fd >= 0 else { throw GuestMemoryFailure.system(errno) }
      var owned = true
      defer { if owned { _ = close(fd) } }
      let reading = try withUnsafeTemporaryAllocation(of: UInt8.self, capacity: meminfoLimit) {
        (buffer: UnsafeMutableBufferPointer<UInt8>) throws -> Value in
        var filled = 0
        while true {
          // The allocation is non-empty and `filled < count`, so the base address exists.
          let count = read(fd, buffer.baseAddress! + filled, buffer.count - filled)
          if count < 0, errno == EINTR { continue }
          guard count >= 0 else { throw GuestMemoryFailure.system(errno) }
          if count == 0 { break }
          filled += count
          guard filled < buffer.count else { throw GuestMemoryFailure.framing }
        }
        return try consume(UnsafeBufferPointer(rebasing: buffer[..<filled]))
      }
      let closed = close(fd)
      owned = false
      guard closed == 0 else { throw GuestMemoryFailure.system(errno) }
      return reading
    }

    /// Folds per-CPU VM counters into `/proc/meminfo`; call before `snapshot()` for fresh values.
    public static func refreshStatistics() throws {
      let fd = open("/proc/sys/vm/stat_refresh", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
      guard fd >= 0 else { throw GuestMemoryFailure.system(errno) }
      var owned = true
      defer { if owned { _ = close(fd) } }
      var byte: UInt8 = 0
      var count: Int
      repeat { count = read(fd, &byte, 1) } while count < 0 && errno == EINTR
      guard count == 0 else {
        if count < 0 { throw GuestMemoryFailure.system(errno) }
        throw GuestMemoryFailure.framing
      }
      let closed = close(fd)
      owned = false
      guard closed == 0 else { throw GuestMemoryFailure.system(errno) }
    }
  }
#endif
