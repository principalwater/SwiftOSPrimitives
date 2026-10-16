/// Full-byte canaries with a256byte repeating pattern and no proportional scratch allocation.
public enum MemoryCanary {
  public enum Failure: Error, Equatable { case mismatch }

  public static func fill(
    _ bytes: inout MutableSpan<UInt8>, multiplier: UInt8, seed: UInt8
  ) {
    var tile: InlineArray<256, UInt8> = .init(repeating: 0)
    for index in 0..<256 { tile[index] = UInt8(truncatingIfNeeded: index) &* multiplier &+ seed }
    tile.span.withUnsafeBufferPointer { source in
      bytes.withUnsafeMutableBufferPointer { destination in
        var offset = 0
        while offset < destination.count {
          let count = min(256, destination.count - offset)
          // Both ranges stay inside borrowed spans; neither pointer escapes.
          unsafe UnsafeMutableRawPointer(destination.baseAddress.unsafelyUnwrapped + offset)
            .copyMemory(from: source.baseAddress.unsafelyUnwrapped, byteCount: count)
          offset += count
        }
      }
    }
  }

  public static func check(
    _ bytes: borrowing Span<UInt8>, multiplier: UInt8, seed: UInt8
  ) throws(Failure) {
    var tile: InlineArray<256, UInt8> = .init(repeating: 0)
    for index in 0..<256 { tile[index] = UInt8(truncatingIfNeeded: index) &* multiplier &+ seed }
    let matches = tile.span.withUnsafeBufferPointer { pattern in
      bytes.withUnsafeBufferPointer { buffer in
        let source = UnsafeRawBufferPointer(pattern)
        let target = UnsafeRawBufferPointer(buffer)
        for word in 0..<(buffer.count / 8) {
          let offset = word * 8
          if unsafe target.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            != source.loadUnaligned(fromByteOffset: offset & 255, as: UInt64.self)
          { return false }
        }
        for index in (buffer.count / 8 * 8)..<buffer.count {
          if unsafe buffer[index] != pattern[index & 255] { return false }
        }
        return true
      }
    }
    guard matches else { throw .mismatch }
  }
}
