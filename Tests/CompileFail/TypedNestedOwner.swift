import BoundedMemory

func replaceOuter(_ arena: inout ScratchArena) {
  _ = arena.withTypedAllocation(of: UInt64.self, capacity: 1) { outer, rest in
    _ = rest.withTypedAllocation(of: UInt64.self, capacity: 1) { inner, _ in
      inner.append(17)
      outer = consume inner
      inner = OutputSpan()
    }
    _ = outer.count
  }
}
