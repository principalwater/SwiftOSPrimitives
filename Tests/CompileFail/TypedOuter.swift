import BoundedMemory

func storeTyped(_ arena: inout ScratchArena) {
  var saved = Span<UInt64>()
  _ = arena.withTypedAllocation(of: UInt64.self, capacity: 1) { output, _ in
    output.append(17)
    saved = output.span
  }
  _ = saved.count
}
