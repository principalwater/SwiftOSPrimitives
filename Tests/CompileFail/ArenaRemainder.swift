import BoundedMemory

func escapeRemainder(_ bytes: inout MutableSpan<UInt8>) {
  let loan = bytes._mutatingExtracting(0..<bytes.count)
  var arena = ScratchArena(storage: consume loan)
  _ = arena.withAllocation(byteCount: 8) { _, remainder in
    let saved = consume remainder
    remainder = ScratchArena(storage: MutableSpan())
    return consume saved
  }
}
