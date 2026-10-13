extension ScratchArena {
  /// Lends storage for at most `capacity` elements, initially with no live elements.
  /// The output span destroys its remaining elements on replacement, return or throw.
  /// Unsafe output operations must not leave live elements outside its tracked count.
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
        defer {
          // No Element remains live: rebind the uninitialized extent and restore byte ownership.
          _ = unsafe raw.initializeMemory(as: UInt8.self, repeating: 0, count: buffer.count)
        }
        // Deinitialized UInt8 remains bound; arbitrary Element is not layout-compatible with it.
        let pointer = unsafe raw.bindMemory(to: type, capacity: capacity)
        let typed = unsafe UnsafeMutableBufferPointer(start: pointer, count: capacity)
        return try unsafe withTypedStorage(typed, remainder: &remainder, body)
      }
    }
  }
}

// The function boundary ends OutputSpan ownership before the caller can rebind/zero its extent.
@unsafe private func withTypedStorage<Element: ~Copyable, Value: ~Copyable, Failure: Error>(
  _ buffer: UnsafeMutableBufferPointer<Element>, remainder: inout ScratchArena,
  _ body: (inout OutputSpan<Element>, inout ScratchArena) throws(Failure) -> Value
) throws(Failure) -> Value {
  var output = unsafe OutputSpan(buffer: buffer, initializedCount: 0)
  return try body(&output, &remainder)
}
