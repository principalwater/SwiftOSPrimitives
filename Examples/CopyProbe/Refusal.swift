@main struct CopyRefusal {
  static func main() {
    var storage: InlineArray<32, UInt8> = .init(repeating: 71)
    var loan = storage.mutableSpan
    loan.withUnsafeMutableBufferPointer { buffer in
      let base = unsafe buffer.baseAddress.unsafelyUnwrapped
      #if COPY_NIL
        _ = unsafe guestMemoryCopy(nil, base, 1)
      #elseif COPY_COUNT
        _ = unsafe guestMemoryCopy(base, base, UInt.max)
      #elseif COPY_OVERFLOW
        // Invalid geometry must be refused before this synthetic address can be dereferenced.
        _ = unsafe guestMemoryCopy(UnsafeMutableRawPointer(bitPattern: UInt.max), base, 1)
      #elseif COPY_OVERLAP
        _ = unsafe guestMemoryCopy(base.advanced(by: 1), base, 16)
      #else
        #error("Select a copy refusal fixture.")
      #endif
    }
  }
}
