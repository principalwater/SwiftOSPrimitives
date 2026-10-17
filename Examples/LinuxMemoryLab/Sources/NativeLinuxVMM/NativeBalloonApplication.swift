/// A coordinator-confirmed target application, distinct from admission or a guest ACK.
public struct NativeBalloonApplication: Sendable {
  public let generation: UInt64
  public let owner: UInt64
  public let epoch: UInt64
  public let targetBytes: UInt64
  public let previousTargetBytes: UInt64
  public let previousOwnedBytes: UInt64
  public let previousActualBytes: UInt64
  public let appliedAt: ContinuousClock.Instant

  func record(since origin: ContinuousClock.Instant) throws -> [String: UInt64] {
    let elapsed = origin.duration(to: appliedAt).components
    guard appliedAt >= origin, elapsed.seconds >= 0,
      UInt64(elapsed.seconds) <= UInt64.max / 1_000_000_000 - 1
    else { throw NativeControlFailure.invariant }
    return [
      "generation": generation, "owner": owner, "epoch": epoch, "targetBytes": targetBytes,
      "previousTargetBytes": previousTargetBytes, "previousOwnedBytes": previousOwnedBytes,
      "previousActualBytes": previousActualBytes,
      "appliedSinceControlStartNanoseconds": UInt64(elapsed.seconds) * 1_000_000_000
        + UInt64(elapsed.attoseconds / 1_000_000_000),
    ]
  }
}
