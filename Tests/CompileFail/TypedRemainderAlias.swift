import BoundedMemory

func aliasRemainder(_ arena: inout ScratchArena) {
  _ = arena.withTypedAllocation(of: UInt8.self, capacity: 1) { output, rest in
    output.append(17)
    rest = ScratchArena(storage: output.mutableSpan)
  }
}
