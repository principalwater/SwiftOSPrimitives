import BoundedMemory

func useArena(_ bytes: inout MutableSpan<UInt8>) -> Int {
  let loan = bytes._mutatingExtracting(0..<bytes.count)
  var arena = ScratchArena(storage: consume loan)
  let outcome = arena.withAllocation(
    byteCount: 8, alignment: 8,
    { reserved, remainder in
      reserved[0] = 73
      return Int(reserved[0]) + remainder.capacity
    })
  let copied = outcome
  switch copied {
  case .allocated(let value): return value
  case .refused: return -1
  }
}

func useTyped(_ arena: inout ScratchArena) -> Int {
  switch arena.withTypedAllocation(
    of: UInt64.self, capacity: 1,
    { output, _ in
      output.append(17)
      return Int(output.span[0])
    })
  {
  case .allocated(let value): return value
  case .refused: return -1
  }
}
