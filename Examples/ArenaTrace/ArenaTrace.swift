/// Caller supplies exclusively owned initialized RAM; this is not a device mapping.
@c(arena_trace)
@unsafe public func arenaTrace(
  _ pointer: UnsafeMutablePointer<UInt8>?, _ capacity: Int,
  _ size: Int, _ alignment: Int
) -> Int {
  guard capacity >= 0 else { return -4 }
  guard let pointer = unsafe pointer else { return -3 }
  let span = unsafe MutableSpan(_unsafeStart: pointer, count: capacity)
  var arena = ScratchArena(storage: consume span)
  switch arena.withAllocation(
    byteCount: size, alignment: alignment,
    { bytes, rest in
      bytes[0] = 17
      bytes[bytes.count - 1] = 29
      switch rest.withAllocation(
        byteCount: 3, alignment: 8,
        { nested, _ in
          nested[0] = 41
          return Int(nested[0])
        })
      {
      case .allocated(let value): return Int(bytes[0]) + Int(bytes[bytes.count - 1]) + value
      case .refused: return Int(bytes[0]) + Int(bytes[bytes.count - 1])
      }
    })
  {
  case .allocated(let value): return value
  case .refused(.invalidSize): return -1
  case .refused(.invalidAlignment): return -2
  case .refused(.capacityExceeded): return -3
  }
}
