import BoundedMemory
import Testing

@Suite struct FrameLedgerTests {
  @Test func alignedReservationsReleaseOutOfOrder() {
    var metadata: InlineArray<9, UInt64> = .init(repeating: 0)
    guard var ledger = FrameLedger(metadata: metadata.mutableSpan, firstFrame: 3) else {
      Issue.record("Valid ledger refused")
      return
    }
    #expect(ledger.capacity == 8 && ledger.availableCount == 8)
    guard case .reserved(let first) = ledger.reserve(frameCount: 2, alignment: 4),
      case .reserved(let second) = ledger.reserve(frameCount: 2, alignment: 2),
      case .reserved(let third) = ledger.reserve(frameCount: 1)
    else {
      Issue.record("Valid frame reservation refused")
      return
    }
    #expect(first.firstFrame == 4 && first.frameCount == 2)
    #expect(second.firstFrame == 6 && second.frameCount == 2)
    #expect(third.firstFrame == 3 && ledger.availableCount == 3)
    guard case .released = ledger.release(consume second) else {
      Issue.record("Second release refused")
      return
    }
    #expect(ledger.availableCount == 5)
    guard case .reserved(let replacement) = ledger.reserve(frameCount: 4, alignment: 2) else {
      Issue.record("Released frames unavailable")
      return
    }
    #expect(replacement.firstFrame == 6 && ledger.availableCount == 1)
    guard case .released = ledger.release(consume first),
      case .released = ledger.release(consume third),
      case .released = ledger.release(consume replacement)
    else {
      Issue.record("Final release refused")
      return
    }
    #expect(ledger.availableCount == 8)
  }

  @Test func fragmentationAndRefusalsPreserveLiveReservations() {
    var metadata: InlineArray<9, UInt64> = .init(repeating: 0)
    guard var ledger = FrameLedger(metadata: metadata.mutableSpan) else {
      Issue.record("Valid ledger refused")
      return
    }
    guard case .reserved(let first) = ledger.reserve(frameCount: 2),
      case .reserved(let middle) = ledger.reserve(frameCount: 2),
      case .reserved(let last) = ledger.reserve(frameCount: 2),
      case .released = ledger.release(consume middle)
    else {
      Issue.record("Initial reservations failed")
      return
    }
    #expect(ledger.availableCount == 4)
    for (count, alignment, expected) in [
      (0, 1, FrameAllocationFailure.invalidSize), (-1, 1, .invalidSize),
      (Int.max, 1, .capacityExceeded), (1, 0, .invalidAlignment),
      (1, 3, .invalidAlignment), (3, 1, .capacityExceeded),
      (1, Int.max, .invalidAlignment), (5, 3, .invalidAlignment),
    ] {
      switch ledger.reserve(frameCount: count, alignment: alignment) {
      case .refused(let reason): #expect(reason == expected)
      case .reserved(let unexpected):
        Issue.record("Invalid/fragmented request admitted")
        _ = ledger.release(consume unexpected)
      }
      #expect(ledger.availableCount == 4)
    }
    guard case .released = ledger.release(consume first),
      case .reserved(let joined) = ledger.reserve(frameCount: 3)
    else {
      Issue.record("Contiguous returned range unavailable")
      return
    }
    #expect(joined.firstFrame == 0 && last.firstFrame == 4)
    guard case .released = ledger.release(consume joined),
      case .released = ledger.release(consume last)
    else {
      Issue.record("Final release failed")
      return
    }
    #expect(ledger.availableCount == 8)
  }

  @Test func foreignReleaseRetainsRightfulCapability() {
    var firstMetadata: InlineArray<5, UInt64> = .init(repeating: 0)
    var secondMetadata: InlineArray<5, UInt64> = .init(repeating: 0)
    guard var first = FrameLedger(metadata: firstMetadata.mutableSpan),
      var second = FrameLedger(metadata: secondMetadata.mutableSpan),
      case .reserved(let reservation) = first.reserve(frameCount: 3)
    else {
      Issue.record("Valid ledgers refused")
      return
    }
    guard case .refused(let returned) = second.release(consume reservation) else {
      Issue.record("Foreign reservation freed")
      return
    }
    #expect(first.availableCount == 1 && second.availableCount == 4)
    #expect(returned.firstFrame == 0 && returned.frameCount == 3)
    guard case .released = first.release(consume returned) else {
      Issue.record("Rightful capability lost")
      return
    }
    #expect(first.availableCount == 4 && second.availableCount == 4)
  }

  @Test func initializationAndGenerationExhaustionFailClosed() {
    var zero: InlineArray<1, UInt64> = .init(repeating: 0)
    switch FrameLedger(metadata: zero.mutableSpan) {
    case .none: break
    case .some: Issue.record("Empty capacity admitted")
    }
    var occupied: InlineArray<3, UInt64> = [0, 1, 0]
    switch FrameLedger(metadata: occupied.mutableSpan) {
    case .none: break
    case .some: Issue.record("Occupied metadata admitted")
    }
    #expect(occupied[1] == 1)
    var overflow: InlineArray<3, UInt64> = .init(repeating: 0)
    switch FrameLedger(metadata: overflow.mutableSpan, firstFrame: UInt.max) {
    case .none: break
    case .some: Issue.record("Overflowing geometry admitted")
    }
    var metadata: InlineArray<3, UInt64> = [UInt64.max - 1, 0, 0]
    do {
      guard var ledger = FrameLedger(metadata: metadata.mutableSpan),
        case .reserved(let final) = ledger.reserve(frameCount: 2)
      else {
        Issue.record("Final valid generation refused")
        return
      }
      #expect(ledger.availableCount == 0)
      switch ledger.reserve(frameCount: 1) {
      case .refused(.generationExhausted): break
      default: Issue.record("Free-count shortcut changed exhaustion precedence")
      }
      guard case .released = ledger.release(consume final) else {
        Issue.record("Final generation release failed")
        return
      }
      switch ledger.reserve(frameCount: 1) {
      case .refused(.generationExhausted): break
      case .reserved(let unexpected):
        Issue.record("Generation wrapped")
        _ = ledger.release(consume unexpected)
      default: Issue.record("Wrong exhaustion reason")
      }
      #expect(ledger.availableCount == 2)
    }
    // The caller-visible persistent counter is part of the documented metadata format.
    #expect(metadata[0] == UInt64.max && metadata[1] == 0 && metadata[2] == 0)
    guard var exhausted = FrameLedger(metadata: metadata.mutableSpan) else {
      Issue.record("Empty exhausted metadata refused")
      return
    }
    for (count, alignment, expected) in [
      (0, 1, FrameAllocationFailure.invalidSize), (1, 0, .invalidAlignment),
      (3, 1, .capacityExceeded), (1, 1, .generationExhausted),
    ] {
      switch exhausted.reserve(frameCount: count, alignment: alignment) {
      case .refused(let reason): #expect(reason == expected)
      default: Issue.record("Exhausted initialization changed refusal precedence")
      }
      #expect(exhausted.availableCount == 2)
    }
  }

  @Test func reusePreservesCounterAndDroppedTicketKeepsCapacity() {
    var metadata: InlineArray<5, UInt64> = .init(repeating: 0)
    for _ in 0..<3 {
      guard var ledger = FrameLedger(metadata: metadata.mutableSpan),
        case .reserved(let ticket) = ledger.reserve(frameCount: 4),
        case .released = ledger.release(consume ticket)
      else {
        Issue.record("Reusable metadata refused")
        return
      }
      #expect(ledger.availableCount == 4)
    }
    #expect(metadata[0] == 3)
    do {
      guard var ledger = FrameLedger(metadata: metadata.mutableSpan) else {
        Issue.record("Valid ledger refused")
        return
      }
      for (count, alignment) in [(0, 1), (5, 1), (1, 3)] {
        guard case .refused = ledger.reserve(frameCount: count, alignment: alignment) else {
          Issue.record("Invalid request admitted")
          return
        }
      }
      #expect(ledger.availableCount == 4)
    }
    #expect(metadata[0] == 3)
    do {
      guard var ledger = FrameLedger(metadata: metadata.mutableSpan),
        case .reserved(let dropped) = ledger.reserve(frameCount: 2)
      else {
        Issue.record("Valid request refused")
        return
      }
      _ = consume dropped
      #expect(ledger.availableCount == 2)
      for (count, alignment) in [(3, 1), (2, 4)] {
        guard
          case .refused(.capacityExceeded) = ledger.reserve(
            frameCount: count, alignment: alignment)
        else {
          Issue.record("Unsatisfiable request admitted")
          return
        }
      }
      #expect(ledger.availableCount == 2)
    }
    switch FrameLedger(metadata: metadata.mutableSpan) {
    case .none: break
    case .some: Issue.record("Dropped reservation silently recovered")
    }
    #expect(metadata[0] == 4)
  }

  @Test func exclusiveEndAndLargeAlignmentAreChecked() {
    var metadata: InlineArray<5, UInt64> = .init(repeating: 0)
    do {
      guard var ledger = FrameLedger(metadata: metadata.mutableSpan, firstFrame: UInt.max - 4),
        case .reserved(let ticket) = ledger.reserve(frameCount: 2, alignment: 2)
      else {
        Issue.record("Valid top-of-space geometry refused")
        return
      }
      #expect(ticket.firstFrame == UInt.max - 3)
      guard case .released = ledger.release(consume ticket) else {
        Issue.record("Boundary release failed")
        return
      }
    }
    switch FrameLedger(metadata: metadata.mutableSpan, firstFrame: UInt.max - 3) {
    case .none: break
    case .some: Issue.record("Exclusive end overflow admitted")
    }
    guard var ledger = FrameLedger(metadata: metadata.mutableSpan, firstFrame: 3) else {
      Issue.record("Valid base refused")
      return
    }
    let alignment = 1 << (Int.bitWidth - 2)
    guard case .refused(.capacityExceeded) = ledger.reserve(frameCount: 1, alignment: alignment)
    else {
      Issue.record("Out-of-capacity alignment admitted")
      return
    }
    #expect(ledger.availableCount == 4)
  }

  @Test func unsafeMetadataFaultsRefuseBeforePartialRelease() {
    // Explicit fault injection bypasses span exclusivity only in this owner-boundary test.
    for (base, extent) in [(UInt(0), 5), (100, 5), (0, 2)] {
      var metadata: InlineArray<5, UInt64> = .init(repeating: 0)
      var loan = metadata.mutableSpan
      loan.withUnsafeMutableBufferPointer { buffer in
        let pointer = unsafe buffer.baseAddress.unsafelyUnwrapped
        var old: FrameAllocation = .refused(.invalidSize)
        do {
          let storage = unsafe MutableSpan(_unsafeStart: pointer, count: buffer.count)
          guard var original = FrameLedger(metadata: consume storage) else {
            Issue.record("Original ledger refused")
            return
          }
          old = original.reserve(frameCount: 2)
        }
        // Keep the persistent generation while simulating lost frame-slot state.
        for index in 1..<buffer.count { unsafe pointer[index] = 0 }
        let storage = unsafe MutableSpan(_unsafeStart: pointer, count: extent)
        guard var current = FrameLedger(metadata: consume storage, firstFrame: base),
          case .reserved(let live) = current.reserve(frameCount: extent == 2 ? 1 : 2),
          case .reserved(let stale) = consume old
        else {
          Issue.record("Fault setup failed")
          return
        }
        let header = unsafe pointer[0]
        let first = unsafe pointer[1]
        let second = unsafe pointer[2]
        guard case .refused(let returned) = current.release(consume stale) else {
          Issue.record("Stale/changed geometry release accepted")
          return
        }
        _ = consume returned
        #expect(unsafe pointer[0] == header && pointer[1] == first && pointer[2] == second)
        if extent > 2 {
          // A later slot mismatch must not free the first matching slot.
          // Only refused calls run before restoration; successful calls would desync the cache.
          unsafe pointer[2] = 0
          guard case .refused(let held) = current.release(consume live) else {
            Issue.record("Partial mismatch accepted")
            return
          }
          #expect(unsafe pointer[1] == first)
          unsafe pointer[2] = second
          guard case .released = current.release(consume held) else {
            Issue.record("Restored reservation refused")
            return
          }
        } else {
          guard case .released = current.release(consume live) else {
            Issue.record("Live reservation lost")
            return
          }
        }
        #expect(current.availableCount == extent - 1)
      }
    }
  }
}
