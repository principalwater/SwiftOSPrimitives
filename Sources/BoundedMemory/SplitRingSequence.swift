/// Bounded arithmetic for one-at-a-time split-ring submissions.
/// This metadata never establishes device completion, DMA provenance or permission to reuse RAM.
public struct SplitRingSequence: Sendable {
  /// A nonzero power of two, bounded by the split-ring limit.
  public let queueSize: UInt16
  /// Full lifetime count, distinct from the wrapping wire index.
  public private(set) var completedCount: UInt64

  /// Creates sequence metadata; recovering a live queue requires independent device validation.
  public init?(queueSize: UInt16, completedCount: UInt64 = 0) {
    guard queueSize > 0, queueSize <= 32768, queueSize & (queueSize - 1) == 0 else { return nil }
    self.queueSize = queueSize
    self.completedCount = completedCount
  }

  /// Current 16-bit producer/consumer index, wrapping only at the wire boundary.
  public var wireIndex: UInt16 { UInt16(truncatingIfNeeded: completedCount) }
  /// Slot for the next available/used entry.
  public var ringSlot: UInt16 { UInt16(completedCount % UInt64(queueSize)) }
  /// Rotates descriptor identity between laps; finite IDs do not prevent arbitrary device replay.
  public var descriptorHead: UInt16 {
    let size = UInt64(queueSize)
    return UInt16((completedCount % size + (completedCount / size) % size) % size)
  }
  /// Exhaustion refuses a new submission before any device publication.
  public var isExhausted: Bool { completedCount == UInt64.max }

  /// Advances metadata after the caller independently validates completion; refuses overflow.
  public mutating func advance() -> Bool {
    guard !isExhausted else { return false }
    completedCount += 1
    return true
  }
}
