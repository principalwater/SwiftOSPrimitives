import BoundedMemory

func escapeTyped(_ arena: inout ScratchArena) {
  _ = arena.withTypedAllocation(of: UInt64.self, capacity: 1) { output, _ in
    output.append(17)
    return output.span
  }
}
