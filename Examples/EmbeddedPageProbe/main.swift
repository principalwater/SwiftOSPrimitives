#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#else
  import Musl
#endif
#if !PAGEMEMORY_STANDALONE
  import PageMemory
#endif

// This consumer is built together with PageMemory in Embedded mode, without Foundation.
func emit(_ text: StaticString) {
  var offset = 0
  while offset < text.utf8CodeUnitCount {
    let count = unsafe write(
      1, text.utf8Start.advanced(by: offset), text.utf8CodeUnitCount - offset)
    guard count > 0 else { exit(5) }
    offset += count
  }
}

@main struct EmbeddedPageProbe {
  enum PayloadFailure: Error, Equatable { case rejected }
  struct Token: ~Copyable { let value: Int }

  static func main() {
    do {
      do {
        _ = try PageRegion.allocate(byteCount: 0)
        exit(3)
      } catch PageMemoryError.invalidSize {}
      var region = try PageRegion.allocate(byteCount: 65_536)
      guard region.mappedByteCount >= region.byteCount else { exit(3) }
      let pageSize = region.pageSize
      var digest: UInt64 = 0
      for cycle in 0..<1000 {
        let value = UInt8(cycle % 251 + 1)
        try region.withMutableBytes { bytes in
          for offset in stride(from: 0, to: bytes.count, by: pageSize) {
            bytes[offset] = value
          }
          bytes[bytes.count - 1] = value
        }
        digest += try region.withBytes { bytes in UInt64(bytes[0]) }
        _ = try region.discardContents(using: .reusable)
        do {
          _ = try region.withBytes { $0[0] }
          exit(3)
        } catch PageMemoryError.contentsDiscarded {}
        try region.resetToZero()
        guard try region.withBytes({ $0[0] == 0 && $0[$0.count - 1] == 0 }) else { exit(3) }
      }
      guard digest == 125_506 else { exit(3) }
      let token = try region.withBytes { _ in Token(value: 73) }
      guard token.value == 73 else { exit(3) }
      do {
        try region.withWriteAccess { (bytes: inout MutableSpan<UInt8>) throws(PayloadFailure) in
          bytes[0] = 91
          throw .rejected
        }
        exit(3)
      } catch PayloadFailure.rejected {}
      guard try region.withBytes({ $0[0] }) == 91 else { exit(3) }
      try region.release()
      try region.release()
      guard region.isReleased else { exit(3) }
      let snapshot = try ProcessMemorySnapshot.capture()
      guard snapshot.residentBytes > 0 else { exit(3) }
      emit("{\"embedded_page_probe\":\"pass\",\"cycles\":1000,\"digest\":125506}\n")
    } catch {
      emit("Embedded page probe refused\n")
      exit(2)
    }
  }
}
