@main struct FrameProbe {
  static func main() {
    var metadata: InlineArray<129, UInt64> = .init(repeating: 0)
    var loan = metadata.mutableSpan
    let checksum = loan.withUnsafeMutableBufferPointer { buffer in
      unsafe frameTrace(buffer.baseAddress, buffer.count, 1000, 3)
    }
    precondition(checksum == 511500)
    precondition(metadata[0] == 3000)
    for index in 1..<129 { precondition(metadata[index] == 0) }
  }
}
