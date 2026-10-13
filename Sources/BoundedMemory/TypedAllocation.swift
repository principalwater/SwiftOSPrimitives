extension ScratchArena {
  /// Lends storage for at most `capacity` elements, initially with no live elements.
  /// The standard-library output span destroys its remaining elements on return or throw.
  /// Reserved bytes are then restored as initialized zero bytes, including unused slots.
  /// Refusal leaves bytes untouched; this library owns no backing allocation or tracking heap.
  /// Constructors, destructors and ordinary Swift runtime work may allocate or block.
  /// This is scoped ownership, not immovable placement, physical pinning or secure erasure.
  public mutating func withTypedAllocation<Element: ~Copyable, Value: ~Copyable, Failure: Error>(
    of type: Element.Type, capacity: Int,
    _ body: (inout OutputSpan<Element>, inout ScratchArena) throws(Failure) -> Value
  ) throws(Failure) -> AllocationOutcome<Value> {
    let stride = MemoryLayout<Element>.stride
    guard capacity > 0, capacity <= Int.max / stride else { return .refused(.invalidSize) }
    return try withAllocation(
      byteCount: capacity * stride, alignment: MemoryLayout<Element>.alignment
    ) { bytes, remainder throws(Failure) in
      try bytes.withUnsafeMutableBufferPointer { buffer throws(Failure) in
        // A positive admitted extent has a base; UInt8 has no destructor or invalid bit pattern.
        let base = unsafe buffer.baseAddress.unsafelyUnwrapped
        let raw = unsafe base.deinitialize(count: buffer.count)
        defer { unsafe base.initialize(repeating: 0, count: buffer.count) }
        return try unsafe raw.withMemoryRebound(to: type, capacity: capacity) {
          pointer throws(Failure) in
          let typed = unsafe UnsafeMutableBufferPointer(start: pointer, count: capacity)
          var output = unsafe OutputSpan(buffer: typed, initializedCount: 0)
          return try body(&output, &remainder)
        }
      }
    }
  }
}
