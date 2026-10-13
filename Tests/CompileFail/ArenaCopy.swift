import BoundedMemory

func take(_ value: consuming ScratchArena) {}
func copyArena(_ bytes: inout MutableSpan<UInt8>) {
  let loan = bytes._mutatingExtracting(0..<bytes.count)
  let arena = ScratchArena(storage: consume loan)
  take(arena)
  take(arena)
}
