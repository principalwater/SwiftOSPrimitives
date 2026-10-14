@main struct CopyProbe {
  static func main() {
    var source: InlineArray<128, UInt8> = .init(repeating: 0)
    for index in 0..<128 { source[index] = UInt8(index) }
    var destination: InlineArray<128, UInt8> = .init(repeating: 71)
    source.span.withUnsafeBufferPointer { input in
      var loan = destination.mutableSpan
      loan.withUnsafeMutableBufferPointer { output in
        let read = unsafe input.baseAddress.unsafelyUnwrapped
        let write = unsafe output.baseAddress.unsafelyUnwrapped
        for readOffset in 0..<16 {
          for writeOffset in 0..<16 {
            for count in 0...65 {
              for index in 0..<128 { unsafe write[index] = 71 }
              let expectedPointer = unsafe UnsafeMutableRawPointer(write.advanced(by: writeOffset))
              let returned = unsafe guestMemoryCopy(
                expectedPointer, UnsafeRawPointer(read.advanced(by: readOffset)), UInt(count))
              precondition(unsafe returned == expectedPointer)
              for index in 0..<128 {
                let expected: UInt8 =
                  (writeOffset..<(writeOffset + count)).contains(index)
                  ? UInt8(readOffset + index - writeOffset) : 71
                precondition(unsafe write[index] == expected && read[index] == UInt8(index))
              }
            }
          }
        }
        precondition(unsafe guestMemoryCopy(write, write, 128) == UnsafeMutableRawPointer(write))
      }
    }
    precondition(unsafe guestMemoryCopy(nil, nil, 0) == nil)
  }
}
