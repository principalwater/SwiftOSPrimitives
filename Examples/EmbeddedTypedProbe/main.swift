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
      let loan = storage.mutableSpan
      let base = loan.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
      let alignment = MemoryLayout<Token>.alignment
      var first = 0
      while (base + UInt(first)) % UInt(alignment) != 0 { first += 1 }
      let end = first + 4 * MemoryLayout<Token>.stride
      var arena = ScratchArena(storage: consume loan)
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
          switch arena.withAllocation(
            byteCount: 1024,
            { bytes, _ in
              for index in first..<end { precondition(bytes[index] == 0) }
              for index in 0..<first { precondition(bytes[index] == 71) }
              precondition(bytes[1023] == 71)
            })
          {
          case .allocated: break
          case .refused: preconditionFailure("Failed typed request leaked its byte loan")
          }
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
      switch arena.withAllocation(
        byteCount: 1024,
        { bytes, _ in
          for index in first..<(end + 8) { precondition(bytes[index] == 0) }
          for index in 0..<first { precondition(bytes[index] == 71) }
          precondition(bytes[1023] == 71)
        })
      {
      case .allocated: break
      case .refused: preconditionFailure("Final byte loan refused")
      }

    }
    precondition(destroyed == 37000)
  }
}
