#if !BOUNDEDMEMORY_STANDALONE
  import BoundedMemory
#endif

@main struct EmbeddedArenaProbe {
  enum Payload: Error { case rejected(Int) }

  static func main() {
    var storage: InlineArray<257, UInt8> = .init(repeating: 0)
    var digest = 0
    do {
      var span = storage.mutableSpan
      let unaligned = span._mutatingExtracting(1..<257)
      var arena = ScratchArena(storage: consume unaligned)
      for iteration in 0..<1000 {
        let alignment = 1 << (iteration % 7)
        switch arena.withAllocation(
          byteCount: 7, alignment: alignment,
          { bytes, remainder in
            let first = bytes.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
            precondition(first % UInt(alignment) == 0)
            bytes[0] = 19
            bytes[6] = 23
            let value = remainder.withAllocation(byteCount: 9, alignment: 16) { nested, _ in
              let second = nested.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
              precondition(second >= first + 7 && second % 16 == 0)
              nested[0] = 41
              nested[8] = 43
              return Int(nested[0]) + Int(nested[8])
            }
            switch value {
            case .allocated(let nested): return Int(bytes[0]) + Int(bytes[6]) + nested
            case .refused: preconditionFailure("Nested allocation refused")
            }
          })
        {
        case .allocated(let value): digest += value
        case .refused: preconditionFailure("Allocation refused")
        }
      }
      switch arena.withAllocation(byteCount: Int.max, { _, _ in -99 }) {
      case .refused(.capacityExceeded): break
      default: preconditionFailure("Invalid capacity accepted")
      }
      do {
        let _: AllocationOutcome<Int> = try arena.withAllocation(byteCount: 256) {
          bytes, remainder throws(Payload) in
          precondition(remainder.capacity == 0)
          bytes[255] = 73
          throw .rejected(29)
        }
        preconditionFailure("Callback error lost")
      } catch {
        switch error { case .rejected(let value): precondition(value == 29) }
      }
      switch arena.withAllocation(byteCount: 256, { bytes, _ in Int(bytes[255]) }) {
      case .allocated(let value): precondition(value == 73)
      case .refused: preconditionFailure("Callback leaked a reservation")
      }
    }
    precondition(storage[0] == 0 && digest == 126000)
  }
}
