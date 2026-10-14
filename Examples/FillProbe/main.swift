@main struct FillProbe {
  static func main() {
    var storage: InlineArray<256, UInt8> = .init(repeating: 71)
    let values: InlineArray<4, Int32> = [-1, 0, 0x123, 0x80]
    var span = storage.mutableSpan
    span.withUnsafeMutableBufferPointer { buffer in
      let base = unsafe buffer.baseAddress.unsafelyUnwrapped
      for offset in 0..<16 {
        for length in 0...127 {
          for valueIndex in 0..<4 {
            unsafe base.update(repeating: 71, count: 256)
            let pointer = unsafe UnsafeMutableRawPointer(base.advanced(by: offset))
            let result = unsafe guestMemoryFill(pointer, values[valueIndex], UInt(length))
            precondition(unsafe result == pointer)
            for index in 0..<256 {
              let expected: UInt8 =
                (offset..<(offset + length)).contains(index)
                ? UInt8(truncatingIfNeeded: values[valueIndex]) : 71
              precondition(unsafe base[index] == expected)
            }
          }
        }
      }
      precondition(unsafe guestMemoryFill(nil, -1, 0) == nil)
    }
  }
}
