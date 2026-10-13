import BoundedMemory

func escapeArena(_ bytes: inout MutableSpan<UInt8>) {
  var saved = MutableSpan<UInt8>()
  let loan = bytes._mutatingExtracting(0..<bytes.count)
  var arena = ScratchArena(storage: consume loan)
  _ = arena.withAllocation(byteCount: 8) { reserved, _ in
    saved = consume reserved
    reserved = MutableSpan()
  }
  _ = saved.count
}
