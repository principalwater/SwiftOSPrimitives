import Foundation

/// Observation authority only. Process owners retain handshake, shutdown and retirement authority.
public struct NativeMemoryObserver: Sendable {
  private enum Source: Sendable {
    case session(NativeMemorySession)
    case owner(NativeMemoryService)
  }
  private let source: Source

  init(session: NativeMemorySession) { source = .session(session) }
  init(owner: NativeMemoryService) { source = .owner(owner) }

  /// Returns nil while another observation owns the wire; preserves the original deadline.
  public func observeIfIdle(
    deadline: ContinuousClock.Instant, refreshStatistics: Bool = false
  ) async throws -> NativeMemoryObservation? {
    switch source {
    case .session(let session):
      try await session.observeIfIdle(deadline: deadline, refreshStatistics: refreshStatistics)
    case .owner(let owner):
      try await owner.observeIfIdle(deadline: deadline, refreshStatistics: refreshStatistics)
    }
  }
}
