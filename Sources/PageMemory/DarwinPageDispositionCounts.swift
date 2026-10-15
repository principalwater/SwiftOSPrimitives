#if os(macOS)
  /// Native XNU disposition flags for every page in one owned region.
  /// The selected flag counts are not a partition. No physical release is inferred.
  public struct DarwinPageDispositionCounts: Equatable, Sendable {
    /// Number of queried native pages, including rounded allocation padding.
    public let pageCount: Int
    /// Pages reported PRESENT by XNU; this is not proof of exclusive physical residency.
    public let presentPages: Int
    /// Pages reported PAGED_OUT, including compressor-backed contents.
    public let pagedOutPages: Int
    /// Pages reported REUSABLE; these may remain resident despite a smaller ledger.
    public let reusablePages: Int
  }
#endif
