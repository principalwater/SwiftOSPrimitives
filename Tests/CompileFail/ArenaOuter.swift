import BoundedMemory

func stashArena(_ bytes: inout MutableSpan<UInt8>) {
  var saved = ScratchArena(storage: MutableSpan())
  let loan = bytes._mutatingExtracting(0..<bytes.count)
  var arena = ScratchArena(storage: consume loan)
  _ = arena.withAllocation(byteCount: 8) { _, remainder in
    saved = consume remainder
    remainder = ScratchArena(storage: MutableSpan())
  }
  _ = saved.capacity
}
