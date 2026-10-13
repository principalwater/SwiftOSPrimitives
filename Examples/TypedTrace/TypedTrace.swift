// The counter pointer is valid until the enclosing scoped callback and destruction end.
@safe private struct TraceToken: ~Copyable {
  let counter: UnsafeMutablePointer<Int>
  deinit { unsafe counter.pointee += 17 }
}

/// The caller supplies an exclusive initialized byte extent; no device or foreign objects.
@c(typed_arena_trace)
@unsafe public func typedArenaTrace(
  _ pointer: UnsafeMutablePointer<UInt8>?, _ byteCapacity: Int, _ count: Int
) -> Int {
  guard byteCapacity >= 0 else { return -4 }
  guard let pointer = unsafe pointer else { return -3 }
  let span = unsafe MutableSpan(_unsafeStart: pointer, count: byteCapacity)
  var arena = ScratchArena(storage: consume span)
  var destroyed = 0
  let result = withUnsafeMutablePointer(to: &destroyed) { counter in
    switch arena.withTypedAllocation(
      of: TraceToken.self, capacity: count,
      { output, _ in
        output.append(unsafe TraceToken(counter: counter))
        return output.count
      })
    {
    case .allocated(let value): return value
    case .refused(.invalidSize): return -1
    case .refused: return -3
    }
  }
  return result + destroyed
}
