#if os(Linux)
  import PageMemory

  #if canImport(Musl)
    import Musl
  #else
    import Glibc
  #endif

  private enum Failure: Error { case system, framing, integrity }
  private func emit(_ text: String) throws {
    let bytes = Array(text.utf8)
    var done = 0
    while done < bytes.count {
      let count = bytes.withUnsafeBytes { write(1, $0.baseAddress! + done, $0.count - done) }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { throw Failure.system }
      done += count
    }
  }
  private func command() throws -> String {
    var bytes: [UInt8] = []
    while bytes.count < 64 {
      var byte: UInt8 = 0
      let count = read(0, &byte, 1)
      if count < 0, errno == EINTR { continue }
      guard count == 1 else { throw Failure.framing }
      if byte == 10 { return String(decoding: bytes, as: UTF8.self) }
      guard byte >= 32, byte <= 126 else { throw Failure.framing }
      bytes.append(byte)
    }
    throw Failure.framing
  }
  private func memory() throws -> String {
    let fd = open("/proc/meminfo", O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { throw Failure.system }
    defer { _ = close(fd) }
    var bytes = [UInt8](repeating: 0, count: 8192)
    let count = read(fd, &bytes, bytes.count)
    guard count > 0, count < bytes.count else { throw Failure.system }
    let lines = String(decoding: bytes.prefix(count), as: UTF8.self).split(separator: "\n")
    func field(_ key: String) throws -> UInt64 {
      let values = lines.filter { $0.hasPrefix(key + ":") }
      guard values.count == 1 else { throw Failure.framing }
      let parts = values[0].split(whereSeparator: { $0 == " " || $0 == "\t" })
      guard parts.count == 3, parts[2] == "kB", let value = UInt64(parts[1]), value < 1 << 40 else {
        throw Failure.framing
      }
      return value * 1024
    }
    return "\(try field("MemTotal")) \(try field("MemAvailable"))"
  }
  @main private struct Probe {
    static func main() {
      do { try run() } catch {
        try? emit("CANARY_FAIL \(error)\n")
        exit(1)
      }
    }
    static func run() throws {
      var region = try PageRegion.allocate(byteCount: 64 << 20)
      try region.withMutableBytes { bytes in
        for index in bytes.indices { bytes[index] = UInt8(truncatingIfNeeded: index &* 17 &+ 91) }
      }
      try emit("CANARY_READY \(try memory())\n")
      for sequence in 1...16 {
        let text = try command()
        guard text == "VERIFY \(sequence)" || text == "QUIT \(sequence)" else {
          throw Failure.framing
        }
        try region.withReadAccess { bytes in
          for index in bytes.indices {
            guard bytes[index] == UInt8(truncatingIfNeeded: index &* 17 &+ 91) else {
              throw Failure.integrity
            }
          }
        }
        try emit("CANARY_OK \(sequence) \(try memory())\n")
        if text.hasPrefix("QUIT") {
          try region.release()
          return
        }
      }
      throw Failure.framing
    }
  }

#else
  @main private struct Probe { static func main() { print("Linux probe only") } }
#endif
