import BoundedMemory
import Testing

private func firstFit(_ occupied: [Bool], count: Int, alignment: Int, base: UInt) -> Int? {
  guard count <= occupied.count else { return nil }
  for offset in 0...(occupied.count - count) {
    if (base + UInt(offset)) % UInt(alignment) == 0,
      (offset..<(offset + count)).allSatisfy({ !occupied[$0] })
    {
      return offset
    }
  }
  return nil
}

extension FrameLedgerTests {
  @Test func countsAndFirstFitMatchIndependentOccupancy() {
    for capacity in [8, 17, 64] {
      for base: UInt in [0, 1, 3, 7] {
        for count in [1, 2, 4] {
          for alignment in [1, 2, 4, 8] {
            var metadata = [UInt64](repeating: 0, count: capacity + 1)
            var occupied = [Bool](repeating: false, count: capacity)
            guard var ledger = FrameLedger(metadata: metadata.mutableSpan, firstFrame: base) else {
              Issue.record("Valid model geometry refused")
              return
            }
            let expectedFirst = firstFit(occupied, count: count, alignment: alignment, base: base)
            guard let firstOffset = expectedFirst else {
              guard
                case .refused(.capacityExceeded) = ledger.reserve(
                  frameCount: count, alignment: alignment)
              else {
                Issue.record("Impossible aligned model range admitted")
                return
              }
              #expect(ledger.availableCount == capacity)
              continue
            }
            guard
              case .reserved(let first) = ledger.reserve(frameCount: count, alignment: alignment)
            else {
              Issue.record("First model range refused")
              return
            }
            #expect(first.firstFrame == base + UInt(firstOffset) && first.frameCount == count)
            for index in firstOffset..<(firstOffset + count) { occupied[index] = true }
            #expect(ledger.availableCount == occupied.filter({ !$0 }).count)
            guard let secondOffset = firstFit(occupied, count: 1, alignment: 2, base: base),
              case .reserved(let second) = ledger.reserve(frameCount: 1, alignment: 2)
            else {
              Issue.record("Second model range refused")
              return
            }
            #expect(second.firstFrame == base + UInt(secondOffset))
            occupied[secondOffset] = true
            #expect(ledger.availableCount == occupied.filter({ !$0 }).count)
            guard case .released = ledger.release(consume first) else {
              Issue.record("Out-of-order model release refused")
              return
            }
            for index in firstOffset..<(firstOffset + count) { occupied[index] = false }
            #expect(ledger.availableCount == occupied.filter({ !$0 }).count)
            let replacementOffset = firstFit(occupied, count: count + 1, alignment: 4, base: base)
            switch ledger.reserve(frameCount: count + 1, alignment: 4) {
            case .refused(.capacityExceeded):
              #expect(replacementOffset == nil)
              #expect(ledger.availableCount == occupied.filter({ !$0 }).count)
            case .reserved(let replacement):
              guard let offset = replacementOffset else {
                Issue.record("Fragmented model refusal incorrectly admitted")
                return
              }
              #expect(replacement.firstFrame == base + UInt(offset))
              for index in offset..<(offset + count + 1) { occupied[index] = true }
              #expect(ledger.availableCount == occupied.filter({ !$0 }).count)
              guard case .released = ledger.release(consume replacement) else {
                Issue.record("Replacement model release refused")
                return
              }
              for index in offset..<(offset + count + 1) { occupied[index] = false }
            default:
              Issue.record("Unexpected model refusal reason")
              return
            }
            #expect(ledger.availableCount == occupied.filter({ !$0 }).count)
            guard case .released = ledger.release(consume second),
              case .reserved(let full) = ledger.reserve(frameCount: capacity)
            else {
              Issue.record("Model did not restore complete capacity")
              return
            }
            #expect(full.firstFrame == base && ledger.availableCount == 0)
            guard case .refused(.capacityExceeded) = ledger.reserve(frameCount: 1),
              case .released = ledger.release(consume full)
            else {
              Issue.record("Full model refusal or release failed")
              return
            }
            #expect(ledger.availableCount == capacity)
          }
        }
      }
    }
  }
}
