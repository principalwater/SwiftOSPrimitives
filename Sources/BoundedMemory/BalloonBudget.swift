/// Bounded planning for a guest's logical resident-memory target, not physical reclaim.
/// Callers supply a fresh guest observation and serialize requests until completion.
public struct BalloonBudget: Sendable {
  public let installedBytes: UInt64
  public let minimumResidentBytes: UInt64
  public let granuleBytes: UInt64
  public let maximumStepBytes: UInt64

  /// Geometry must be aligned; granule is a power of two, at least the4KiB virtio page.
  public init?(
    installedBytes: UInt64, minimumResidentBytes: UInt64, granuleBytes: UInt64,
    maximumStepBytes: UInt64
  ) {
    guard granuleBytes >= 4096, granuleBytes & (granuleBytes - 1) == 0,
      installedBytes > 0, installedBytes % granuleBytes == 0,
      minimumResidentBytes > 0, minimumResidentBytes <= installedBytes,
      minimumResidentBytes % granuleBytes == 0, maximumStepBytes >= granuleBytes,
      maximumStepBytes % granuleBytes == 0
    else { return nil }
    self.installedBytes = installedBytes
    self.minimumResidentBytes = minimumResidentBytes
    self.granuleBytes = granuleBytes
    self.maximumStepBytes = maximumStepBytes
  }

  /// Returns nil for invalid observations/requests; rounds upward to avoid over-reclaim.
  /// Result changes by at most maximumStepBytes and never drops below the resident floor.
  /// It is a request only: transport acknowledgement is not guest/host memory completion.
  public func target(observedResidentBytes: UInt64, requestedResidentBytes: UInt64) -> UInt64? {
    guard observedResidentBytes >= minimumResidentBytes,
      observedResidentBytes <= installedBytes, observedResidentBytes % granuleBytes == 0,
      requestedResidentBytes > 0, requestedResidentBytes <= installedBytes
    else { return nil }
    let requested = max(requestedResidentBytes, minimumResidentBytes)
    let remainder = requested % granuleBytes
    // Aligned installedBytes bounds the rounded result, even near UInt64.max.
    let rounded = remainder == 0 ? requested : requested + (granuleBytes - remainder)
    if rounded < observedResidentBytes {
      return observedResidentBytes - min(observedResidentBytes - rounded, maximumStepBytes)
    }
    return observedResidentBytes + min(rounded - observedResidentBytes, maximumStepBytes)
  }
}
