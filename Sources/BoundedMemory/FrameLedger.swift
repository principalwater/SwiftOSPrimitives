/// Refusals leave allocation metadata untouched.
public enum FrameAllocationFailure: Equatable, Sendable {
  case invalidSize, invalidAlignment, capacityExceeded, generationExhausted
}

/// A generation-bound frame reservation; it grants no pointer or physical-memory access.
@safe public struct FrameReservation: ~Copyable, ~Escapable {
  /// First frame identifier, in the caller's frame-number space.
  public let firstFrame: UInt
  /// Number of contiguous reserved frames.
  public let frameCount: Int
  fileprivate let identity: UInt
  fileprivate let generation: UInt64
  fileprivate let offset: Int

  @_lifetime(copy metadata)
  fileprivate init(
    metadata: borrowing MutableSpan<UInt64>, identity: UInt, generation: UInt64,
    firstFrame: UInt, frameCount: Int, offset: Int
  ) {
    self.identity = identity
    self.generation = generation
    self.firstFrame = firstFrame
    self.frameCount = frameCount
    self.offset = offset
  }
}

/// Either a lifetime-bound reservation or an allocation refusal.
public enum FrameAllocation: ~Copyable, ~Escapable {
  case reserved(FrameReservation)
  case refused(FrameAllocationFailure)
}

/// A refused release preserves the reservation for a surviving rightful ledger.
public enum FrameRelease: ~Copyable, ~Escapable {
  case released
  case refused(FrameReservation)
}

/// Synchronous first-fit frame bookkeeping in exclusively borrowed, initialized UInt64 storage.
/// Slot zero retains the issued-generation counter; every remaining slot must initially be zero.
/// Owns no frames, mapping, heap, ARC object or synchronization. Serialize use in one context.
/// Reservations must be explicitly released; dropping one keeps its frames reserved.
/// Keep the ledger until all tickets are released: replacing/dropping it strands live tickets.
@safe public struct FrameLedger: ~Copyable, ~Escapable {
  private var metadata: MutableSpan<UInt64>
  private let identity: UInt
  private let baseFrame: UInt
  private var freeCount: Int

  /// Returns nil for empty capacity, overflowing geometry or initially occupied frame slots.
  /// The exclusive end `firstFrame + capacity` must fit UInt; an exhausted counter is accepted.
  /// Unsafe pointer-backed callers must never decrease slot zero while stale tickets could exist.
  /// Do not mutate metadata outside this ledger while it is live; availability is cached.
  @_lifetime(copy metadata)
  public init?(metadata: consuming MutableSpan<UInt64>, firstFrame: UInt = 0) {
    guard metadata.count > 1, UInt(metadata.count - 1) <= UInt.max - firstFrame else { return nil }
    for index in 1..<metadata.count { guard metadata[index] == 0 else { return nil } }
    self.identity = metadata.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
    self.baseFrame = firstFrame
    self.freeCount = metadata.count - 1
    self.metadata = metadata
  }

  /// Total managed frame count.
  public var capacity: Int { metadata.count - 1 }
  /// Number of currently free slots. Complexity: O(1).
  public var availableCount: Int { freeCount }

  /// Reserves an aligned contiguous range; alignment is in frame units at the actual baseFrame.
  /// Fragmentation and unsatisfiable alignment both return capacityExceeded.
  /// Complexity: O(capacity); no explicit sleep, syscall or backing allocation is performed.
  @_lifetime(copy self)
  public mutating func reserve(frameCount: Int, alignment: Int = 1) -> FrameAllocation {
    guard frameCount > 0 else { return .refused(.invalidSize) }
    guard alignment > 0, alignment & (alignment - 1) == 0 else {
      return .refused(.invalidAlignment)
    }
    guard frameCount <= capacity else { return .refused(.capacityExceeded) }
    guard metadata[0] < UInt64.max else { return .refused(.generationExhausted) }
    guard frameCount <= freeCount else { return .refused(.capacityExceeded) }
    var offset = 0
    while offset <= capacity - frameCount {
      let padding = Int((0 &- (baseFrame + UInt(offset))) & UInt(alignment - 1))
      guard padding <= capacity - frameCount - offset else { break }
      offset += padding
      var count = 0
      while count < frameCount && metadata[offset + count + 1] == 0 { count += 1 }
      if count == frameCount {
        let generation = metadata[0] + 1
        metadata[0] = generation
        for index in offset..<(offset + frameCount) { metadata[index + 1] = generation }
        freeCount -= frameCount
        return .reserved(
          FrameReservation(
            metadata: metadata, identity: identity, generation: generation,
            firstFrame: baseFrame + UInt(offset), frameCount: frameCount, offset: offset))
      }
      offset += count + 1
    }
    return .refused(.capacityExceeded)
  }

  /// Checks the whole reservation before freeing any slot; a foreign/stale request is unchanged.
  @_lifetime(copy reservation)
  public mutating func release(_ reservation: consuming FrameReservation) -> FrameRelease {
    guard reservation.identity == identity, reservation.generation > 0, reservation.offset >= 0,
      reservation.frameCount > 0, reservation.frameCount <= capacity,
      reservation.offset <= capacity - reservation.frameCount,
      reservation.firstFrame == baseFrame + UInt(reservation.offset)
    else { return .refused(reservation) }
    for index in reservation.offset..<(reservation.offset + reservation.frameCount) {
      guard metadata[index + 1] == reservation.generation else { return .refused(reservation) }
    }
    // Diagnose derived-state corruption before clearing any ownership slot.
    precondition(freeCount <= capacity - reservation.frameCount)
    for index in reservation.offset..<(reservation.offset + reservation.frameCount) {
      metadata[index + 1] = 0
    }
    freeCount += reservation.frameCount
    return .released
  }
}
