#if !BOUNDEDMEMORY_STANDALONE
  import BoundedMemory
#endif

// The counter pointer stays within its enclosing native pointer loan in this fixture.
@safe private struct Token: ~Copyable {
  let identifier: Int
  let counter: UnsafeMutablePointer<Int>
  deinit { unsafe counter.pointee += identifier }
}

@main struct EmbeddedTypedProbe {
  enum Payload: Error { case rejected(Int) }

  static func main() {
    var storage: InlineArray<1024, UInt8> = .init(repeating: 71)
    var destroyed = 0
    withUnsafeMutablePointer(to: &destroyed) { counter in
      var arena = ScratchArena(storage: storage.mutableSpan)
      for iteration in 0..<1000 {
        for count in 0...4 {
          let before = unsafe counter.pointee
          do throws(Payload) {
            let _: AllocationOutcome<Int> = try arena.withTypedAllocation(
              of: Token.self, capacity: 4
            ) { output, _ throws(Payload) in
              for identifier in 1..<(count + 1) {
                output.append(unsafe Token(identifier: identifier, counter: counter))
              }
              precondition(unsafe output.count == count && counter.pointee == before)
              throw .rejected(iteration)
            }
            preconditionFailure("Typed error was swallowed")
          } catch {
            switch error {
            case .rejected(let value): precondition(value == iteration)
            }
          }
          precondition(unsafe counter.pointee == before + count * (count + 1) / 2)
        }
        switch arena.withTypedAllocation(
          of: Token.self, capacity: 4,
          { output, rest in
            output.append(unsafe Token(identifier: 17, counter: counter))
            switch rest.withTypedAllocation(
              of: UInt64.self, capacity: 1,
              { nested, _ in
                nested.append(29)
                precondition(output.span[0].identifier == 17 && nested.span[0] == 29)
              })
            {
            case .allocated: break
            case .refused: preconditionFailure("Nested reservation refused")
            }
            return output.removeLast()
          })
        {
        case .allocated(let independent): precondition(independent.identifier == 17)
        case .refused: preconditionFailure("Typed reservation refused")
        }
      }
      switch arena.withTypedAllocation(of: UInt64.self, capacity: Int.max, { _, _ in -1 }) {
      case .refused(.invalidSize): break
      default: preconditionFailure("Overflow admitted")
      }
    }
    precondition(destroyed == 37000)
    // The first four Token slots and the following nested UInt64 have all been restored.
    for index in 0..<(4 * MemoryLayout<Token>.stride + 8) { precondition(storage[index] == 0) }
    precondition(storage[1023] == 71)
  }
}
