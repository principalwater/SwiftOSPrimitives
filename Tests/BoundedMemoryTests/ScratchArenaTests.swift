import BoundedMemory
import PageMemory
import Testing

struct ScratchArenaTests {
  @Test func refusalLeavesStorageAndCallbackUntouched() {
    var backing = [UInt8](repeating: 71, count: 64)
    do {
      var arena = ScratchArena(storage: backing.mutableSpan)
      for (size, alignment, expected) in [
        (0, 1, AllocationFailure.invalidSize), (-1, 1, .invalidSize),
        (8, 0, .invalidAlignment), (8, -2, .invalidAlignment), (8, 3, .invalidAlignment),
        (65, 1, .capacityExceeded), (Int.max, 1, .capacityExceeded),
        (Int.max, 1 << (Int.bitWidth - 2), .capacityExceeded),
      ] {
        var called = false
        switch arena.withAllocation(
          byteCount: size, alignment: alignment,
          { _, _ in
            called = true
          })
        {
        case .refused(let reason): #expect(reason == expected)
        case .allocated: Issue.record("Invalid request was admitted")
        }
        #expect(!called)
        #expect(arena.capacity == 64)
      }
    }
    #expect(backing == [UInt8](repeating: 71, count: 64))
    var empty = ScratchArena(storage: MutableSpan<UInt8>())
    switch empty.withAllocation(byteCount: 1, { _, _ in false }) {
    case .refused(let reason): #expect(reason == .capacityExceeded)
    case .allocated: Issue.record("Empty arena admitted a byte")
    }
  }

  @Test func actualAddressAlignmentAndDisjointNestedLoans() {
    var backing = [UInt8](repeating: 0, count: 257)
    do {
      var span = backing.mutableSpan
      let unaligned = span._mutatingExtracting(1..<257)
      var arena = ScratchArena(storage: consume unaligned)
      for alignment in [1, 2, 4, 8, 16, 32, 64] {
        switch arena.withAllocation(
          byteCount: 7, alignment: alignment,
          { bytes, remainder in
            let first = bytes.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
            #expect(first % UInt(alignment) == 0)
            bytes[0] = 19
            bytes[6] = 23
            switch remainder.withAllocation(
              byteCount: 9, alignment: 16,
              { nested, _ in
                let second = nested.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
                #expect(second >= first + 7)
                #expect(second % 16 == 0)
                nested[0] = 41
                nested[8] = 43
              })
            {
            case .allocated: break
            case .refused: Issue.record("Nested reservation unexpectedly refused")
            }
            #expect(bytes[0] == 19 && bytes[6] == 23)
          })
        {
        case .allocated: break
        case .refused: Issue.record("Aligned reservation unexpectedly refused")
        }
      }
    }
    #expect(backing[0] == 0)

    // Independent first-fit reference scans actual addresses instead of using the arena bit mask.
    var grid = [UInt8](repeating: 0, count: 256)
    var span = grid.mutableSpan
    let base = span.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
    for start in 0..<64 {
      for capacity in [0, 1, 2, 7, 8, 15, 16, 31, 32, 63, 64, 65, 95] {
        for alignment in [
          1, 2, 4, 8, 16, 32, 64, 128, 4096, 0, -1, 3, 6,
          Int.min, Int.max, 1 << (Int.bitWidth - 2),
        ] {
          for size in [-1, 0, 1, 7, 31, capacity + 1, Int.max] {
            var expected: AllocationFailure?
            var firstFit: Int?
            if size <= 0 {
              expected = .invalidSize
            } else if alignment <= 0 || alignment.nonzeroBitCount != 1 {
              expected = .invalidAlignment
            } else {
              firstFit = (0..<capacity).first {
                (base + UInt(start + $0)) % UInt(alignment) == 0 && size <= capacity - $0
              }
              if firstFit == nil { expected = .capacityExceeded }
            }
            let loan = span._mutatingExtracting(start..<(start + capacity))
            var arena = ScratchArena(storage: consume loan)
            switch arena.withAllocation(
              byteCount: size, alignment: alignment,
              { bytes, rest in
                let address = bytes.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
                #expect(firstFit != nil && expected == nil)
                #expect(address == base + UInt(start + (firstFit ?? 0)))
                #expect(bytes.count == size)
                #expect(rest.capacity == capacity - (firstFit ?? 0) - size)
                return 73
              })
            {
            case .allocated(let value): #expect(value == 73 && firstFit != nil)
            case .refused(let reason): #expect(reason == expected && firstFit == nil)
            }
          }
        }
      }
    }

  }

  @Test func errorsReleaseReservationsAndPreserveOriginalPayload() throws {
    enum Payload: Error, Equatable { case refusedByConsumer(Int) }
    struct Token: ~Copyable { let value: Int }
    var backing = [UInt8](repeating: 0, count: 16)
    var arena = ScratchArena(storage: backing.mutableSpan)
    do {
      let _: AllocationOutcome<Int> = try arena.withAllocation(byteCount: 16) {
        bytes, rest throws(Payload) in
        #expect(rest.capacity == 0)
        bytes[15] = 73
        throw .refusedByConsumer(29)
      }
      Issue.record("Consumer error was swallowed")
    } catch { #expect(error == .refusedByConsumer(29)) }
    switch arena.withAllocation(
      byteCount: 16,
      { bytes, rest in
        #expect(rest.capacity == 0)
        return Token(value: Int(bytes[15]))
      })
    {
    case .allocated(let token): #expect(token.value == 73)
    case .refused: Issue.record("Failed callback leaked its reservation")
    }
  }

  @Test func pageOwnerRetainsItsReclamationBoundary() throws {
    var region = try PageRegion.allocate(byteCount: 4096)
    try region.withMutableBytes { bytes in
      let loan = bytes._mutatingExtracting(0..<bytes.count)
      var arena = ScratchArena(storage: consume loan)
      switch arena.withAllocation(byteCount: 4096, { reserved, _ in reserved[4095] = 91 }) {
      case .allocated: break
      case .refused: Issue.record("Page reservation unexpectedly refused")
      }
    }
    #expect(try region.withBytes { $0[4095] } == 91)
    _ = try region.discardContents()
    try region.resetToZero()
    #expect(try region.withBytes { $0[4095] } == 0)
    try region.release()
    let released = region.isReleased
    #expect(released)
  }
}
