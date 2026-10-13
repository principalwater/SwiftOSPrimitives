import BoundedMemory

func reenterArena(_ bytes: inout MutableSpan<UInt8>) {
  let loan = bytes._mutatingExtracting(0..<bytes.count)
  var arena = ScratchArena(storage: consume loan)
  _ = arena.withAllocation(byteCount: 8) { _, _ in
    _ = arena.withAllocation(byteCount: 8) { _, _ in 73 }
  }
}
