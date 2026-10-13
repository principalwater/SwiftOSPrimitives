import BoundedMemory
import PageMemory
import Testing

private final class DestructionLedger {
  var identifiers: [Int] = []
}

private struct TrackedElement: ~Copyable {
  let identifier: Int
  let ledger: DestructionLedger
  deinit { ledger.identifiers.append(identifier) }
}

private final class OwnedResource {
  let ledger: DestructionLedger
  init(ledger: DestructionLedger) { self.ledger = ledger }
  deinit { ledger.identifiers.append(73) }
}

struct TypedArenaTests {
  @Test func nestedNontrivialFailuresDestroyBothPrefixesAndRetype() {
    enum Payload: Error, Equatable { case inner, outer }
    let ledger = DestructionLedger()
    var backing = [UInt8](repeating: 71, count: 256)
    var arena = ScratchArena(storage: backing.mutableSpan)
    for innerThrows in [true, false] {
      ledger.identifiers = []
      do throws(Payload) {
        let _: AllocationOutcome<Int> = try arena.withTypedAllocation(
          of: TrackedElement.self, capacity: 2
        ) { outer, rest throws(Payload) in
          outer.append(TrackedElement(identifier: 1, ledger: ledger))
          let nested = try rest.withTypedAllocation(of: TrackedElement.self, capacity: 2) {
            inner, _ throws(Payload) in
            inner.append(TrackedElement(identifier: 2, ledger: ledger))
            if innerThrows { throw .inner }
            return 29
          }
          switch nested {
          case .allocated(let value): #expect(value == 29 && ledger.identifiers == [2])
          case .refused: Issue.record("Nested typed request refused")
          }
          #expect(outer.span[0].identifier == 1)
          throw .outer
        }
        Issue.record("Nested typed error swallowed")
      } catch { #expect(error == (innerThrows ? .inner : .outer)) }
      #expect(ledger.identifiers == [2, 1])
      // A different trivial type may bind the same deinitialized extent after the failure.
      switch arena.withTypedAllocation(
        of: UInt64.self, capacity: 4,
        { output, _ in
          output.append(73)
          return output.span[0]
        })
      {
      case .allocated(let value): #expect(value == 73)
      case .refused: Issue.record("Retyping after nested failure refused")
      }
    }
  }

  @Test func variedLayoutsEmptyStorageAndExactFit() {
    struct Empty {}
    struct Padded {
      let first: UInt64
      let last: UInt8
    }
    struct Triple {
      let first: UInt64
      let second: UInt64
      let last: UInt8
    }
    @_alignment(16) struct Aligned { let value: UInt64 }
    func exercise<Element>(_ value: Element) {
      let stride = MemoryLayout<Element>.stride
      let alignment = MemoryLayout<Element>.alignment
      var backing = [UInt8](repeating: 71, count: 129)
      var span = backing.mutableSpan
      let base = span.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
      let first = (1..<(1 + alignment)).first { (base + UInt($0)) % UInt(alignment) == 0 } ?? 1
      let loan = span._mutatingExtracting(first..<(first + 3 * stride))
      var arena = ScratchArena(storage: consume loan)
      switch arena.withTypedAllocation(
        of: Element.self, capacity: 3,
        { output, rest in
          #expect(rest.capacity == 0 && output.capacity == 3)
          output.append(value)
          output.append(value)
          output.append(value)
          #expect(output.count == 3)
        })
      {
      case .allocated: break
      case .refused: Issue.record("Exact-fit typed layout refused")
      }
      for count in [Int.max / stride + (stride == 1 ? 0 : 1), Int.max / stride] {
        switch arena.withTypedAllocation(
          of: Element.self, capacity: count,
          { _, _ in
            Issue.record("Huge typed layout admitted")
          })
        {
        case .allocated: break
        case .refused(let reason):
          #expect(reason == (count > Int.max / stride ? .invalidSize : .capacityExceeded))
        }
      }
    }
    exercise(Empty())
    exercise(Padded(first: 17, last: 29))
    exercise(Triple(first: 17, second: 29, last: 41))
    exercise(Aligned(value: 73))
    var empty = ScratchArena(storage: MutableSpan<UInt8>())
    switch empty.withTypedAllocation(
      of: UInt64.self, capacity: 1,
      { _, _ in
        Issue.record("Empty storage admitted typed elements")
      })
    {
    case .allocated: break
    case .refused(let reason): #expect(reason == .capacityExceeded)
    }
  }

  @Test func pageOwnedReferencesEndBeforeReclamation() throws {
    let ledger = DestructionLedger()
    weak var observed: OwnedResource?
    var region = try PageRegion.allocate(byteCount: 4096)
    try region.withMutableBytes { bytes in
      let loan = bytes._mutatingExtracting(0..<bytes.count)
      var arena = ScratchArena(storage: consume loan)
      switch arena.withTypedAllocation(
        of: OwnedResource.self, capacity: 2,
        { output, _ in
          output.append(OwnedResource(ledger: ledger))
          observed = output.span[0]
          #expect(observed != nil && ledger.identifiers.isEmpty)
        })
      {
      case .allocated: break
      case .refused: Issue.record("Page-backed typed reservation refused")
      }
      #expect(observed == nil && ledger.identifiers == [73])
      for index in 0..<(2 * MemoryLayout<OwnedResource>.stride) { #expect(bytes[index] == 0) }
    }
    _ = try region.discardContents()
    try region.resetToZero()
    #expect(try region.withBytes { $0[0] } == 0)
    try region.release()
    #expect(ledger.identifiers == [73])
  }

  @Test func typedRefusalPreservesBytesAndSkipsConstruction() {
    var backing = [UInt8](repeating: 71, count: 32)
    do {
      var arena = ScratchArena(storage: backing.mutableSpan)
      for (count, reason) in [
        (-1, AllocationFailure.invalidSize), (0, .invalidSize),
        (Int.max, .invalidSize), (Int.max / 8 + 1, .invalidSize),
        (Int.max / 8, .capacityExceeded), (5, .capacityExceeded),
      ] {
        var called = false
        switch arena.withTypedAllocation(
          of: UInt64.self, capacity: count,
          { _, _ in
            called = true
          })
        {
        case .allocated: Issue.record("Invalid typed request was admitted")
        case .refused(let actual): #expect(actual == reason)
        }
        #expect(!called)
      }
    }
    #expect(backing == [UInt8](repeating: 71, count: 32))
  }

  @Test func partialConstructionDestroysExactlyOnceBeforeReuse() {
    enum Payload: Error, Equatable { case stopped(Int) }
    let ledger = DestructionLedger()
    var backing = [UInt8](repeating: 71, count: 256)
    var arena = ScratchArena(storage: backing.mutableSpan)
    for count in 0...4 {
      ledger.identifiers = []
      do {
        let _: AllocationOutcome<Int> = try arena.withTypedAllocation(
          of: TrackedElement.self, capacity: 4
        ) { output, _ throws(Payload) in
          #expect(output.isEmpty && output.capacity == 4)
          for identifier in 0..<count {
            output.append(TrackedElement(identifier: identifier, ledger: ledger))
          }
          #expect(output.count == count && ledger.identifiers.isEmpty)
          throw .stopped(count)
        }
        Issue.record("Typed consumer error was swallowed")
      } catch { #expect(error == .stopped(count)) }
      #expect(ledger.identifiers.sorted() == Array(0..<count))
      switch arena.withAllocation(
        byteCount: 256,
        { bytes, _ in
          let base = bytes.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
          let first =
            (0..<MemoryLayout<TrackedElement>.alignment).first {
              (base + UInt($0)) % UInt(MemoryLayout<TrackedElement>.alignment) == 0
            } ?? 0
          for index in first..<(first + 4 * MemoryLayout<TrackedElement>.stride) {
            #expect(bytes[index] == 0)
          }
        })
      {
      case .allocated: break
      case .refused: Issue.record("Failed typed callback leaked the byte loan")
      }
      switch arena.withTypedAllocation(
        of: TrackedElement.self, capacity: 4,
        { output, _ in
          output.append(TrackedElement(identifier: 91, ledger: ledger))
          #expect(output.span[0].identifier == 91)
          return output.count
        })
      {
      case .allocated(let count): #expect(count == 1)
      case .refused: Issue.record("Partial failure leaked capacity")
      }
      #expect(ledger.identifiers.sorted() == Array(0..<count) + [91])
    }
  }

  @Test func replacementAndIndependentOwnershipTransferCleanUp() {
    let ledger = DestructionLedger()
    var backing = [UInt8](repeating: 0, count: 256)
    var arena = ScratchArena(storage: backing.mutableSpan)
    switch arena.withTypedAllocation(
      of: TrackedElement.self, capacity: 2,
      { output, _ in
        output.append(TrackedElement(identifier: 1, ledger: ledger))
        output.append(TrackedElement(identifier: 2, ledger: ledger))
        let independent = output.removeLast()
        output = OutputSpan()
        #expect(ledger.identifiers == [1])
        return independent
      })
    {
    case .allocated(let independent):
      #expect(independent.identifier == 2 && ledger.identifiers == [1])
    case .refused: Issue.record("Independent ownership transfer was refused")
    }
    #expect(ledger.identifiers == [1, 2])
  }

  @Test func typedGeometryAndRestorationRespectAllBoundaries() {
    var backing = [UInt8](repeating: 71, count: 129)
    for start in 0..<16 {
      for capacity in [1, 7, 8, 15, 16, 17, 31, 64] {
        for count in 1...8 {
          backing = [UInt8](repeating: 71, count: 129)
          var reserved: Range<Int>?
          do {
            var span = backing.mutableSpan
            let base = span.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
            let fit = (start..<(start + capacity)).first {
              (base + UInt($0)) % 8 == 0 && count <= (start + capacity - $0) / 8
            }
            let loan = span._mutatingExtracting(start..<(start + capacity))
            var arena = ScratchArena(storage: consume loan)
            switch arena.withTypedAllocation(
              of: UInt64.self, capacity: count,
              { output, rest in
                #expect(fit != nil && output.count == 0 && output.capacity == count)
                output.append(0x1234_5678_9abc_def0)
                let address = output.span.withUnsafeBufferPointer {
                  UInt(bitPattern: $0.baseAddress)
                }
                #expect(address == base + UInt(fit ?? 0))
                #expect(rest.capacity == start + capacity - (fit ?? 0) - count * 8)
                reserved = (fit ?? 0)..<((fit ?? 0) + count * 8)
                if rest.capacity >= 1 {
                  switch rest.withTypedAllocation(
                    of: UInt8.self, capacity: 1,
                    { nested, _ in
                      nested.append(91)
                      #expect(output.span[0] == 0x1234_5678_9abc_def0)
                    })
                  {
                  case .allocated: break
                  case .refused: Issue.record("Disjoint typed remainder was refused")
                  }
                  // The nested typed reservation restores its one byte too.
                  reserved = (fit ?? 0)..<((fit ?? 0) + count * 8 + 1)
                }
              })
            {
            case .allocated: #expect(fit != nil)
            case .refused(let reason): #expect(fit == nil && reason == .capacityExceeded)
            }
          }
          for index in backing.indices {
            #expect(backing[index] == (reserved?.contains(index) == true ? 0 : 71))
          }
        }
      }
    }
  }
}
