import Foundation

public struct NativeMemoryObservation: Sendable {
  public let sequence: UInt64
  /// Earliest host instant of the request, including its transport latency.
  public let capturedAt: ContinuousClock.Instant
  public let total: UInt64
  public let available: UInt64

  public init(
    sequence: UInt64, capturedAt: ContinuousClock.Instant, total: UInt64, available: UInt64
  ) {
    self.sequence = sequence
    self.capturedAt = capturedAt
    self.total = total
    self.available = available
  }
}

/// A separate process and wire keep allocation diagnostics from blocking memory observations.
public actor NativeMemorySession {
  private let wire: any MemorySessionWire
  private let maximumGuestBytes: UInt64
  private var sequence: UInt64 = 0
  private var ready = false
  private var busy = false
  private var closed = false

  init(wire: any MemorySessionWire, maximumGuestBytes: UInt64) throws {
    guard maximumGuestBytes > 0 else { throw NativeControlFailure.arguments }
    self.wire = wire
    self.maximumGuestBytes = maximumGuestBytes
  }

  private func line(
    until deadline: ContinuousClock.Instant, allowAfterClose: Bool = false
  ) async throws -> String {
    while ContinuousClock.now < deadline {
      try Task.checkCancellation()
      guard !closed else { throw NativeControlFailure.disconnected }
      if let text = try wire.takeLine(allowAfterClose: allowAfterClose) { return text }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw NativeControlFailure.wireTimedOut
  }

  /// Accepts one validated READY frame within five seconds; a failed handshake closes the wire.
  public func start() async throws {
    try await start(until: .now.advanced(by: .seconds(5)))
  }

  func start(until deadline: ContinuousClock.Instant) async throws {
    guard !ready, !busy, !closed else { throw NativeControlFailure.invariant }
    busy = true
    defer { busy = false }
    do {
      let text = try await line(until: deadline)
      let words = text.split(separator: " ")
      guard words.count == 3, words[0] == "MEMORY_READY", let total = UInt64(words[1]),
        total > 0, total <= maximumGuestBytes,
        let available = UInt64(words[2]), available <= total,
        text == "MEMORY_READY \(total) \(available)"
      else { throw NativeControlFailure.framing }
      try Task.checkCancellation()
      guard ContinuousClock.now < deadline else { throw NativeControlFailure.wireTimedOut }
      ready = true
    } catch {
      close()
      throw error
    }
  }

  /// Returns nil while another exchange owns the wire; never extends the caller's deadline.
  public func observeIfIdle(
    deadline: ContinuousClock.Instant, refreshStatistics: Bool = false
  ) async throws
    -> NativeMemoryObservation?
  {
    try Task.checkCancellation()
    guard ready, !closed else { throw NativeControlFailure.disconnected }
    guard !busy else { return nil }
    return try await exchange(refreshStatistics ? "OBS_REFRESH" : "OBS", deadline: deadline)
  }

  /// Requests a validated graceful exit; the process owner must still wait and delete the process.
  public func quit() async throws {
    try await quit(until: .now.advanced(by: .seconds(5)))
  }

  func quit(until deadline: ContinuousClock.Instant) async throws {
    guard ready, !busy, !closed else { throw NativeControlFailure.disconnected }
    _ = try await exchange("QUIT", deadline: deadline)
  }

  private func exchange(_ command: String, deadline: ContinuousClock.Instant) async throws
    -> NativeMemoryObservation
  {
    guard ContinuousClock.now < deadline else { throw NativeControlFailure.wireTimedOut }
    busy = true
    defer { busy = false }
    do {
      guard sequence < UInt64.max else { throw NativeControlFailure.invariant }
      sequence += 1
      let capturedAt = ContinuousClock.now
      try await wire.send(Data("\(command) \(sequence)\n".utf8), until: deadline)
      let text = try await line(until: deadline, allowAfterClose: command == "QUIT")
      let words = text.split(separator: " ")
      try Task.checkCancellation()
      guard !closed, words.count == 4, words[0] == "MEMORY_OK",
        words[1] == Substring(String(sequence)), let total = UInt64(words[2]),
        total > 0, total <= maximumGuestBytes,
        let available = UInt64(words[3]), available <= total,
        text == "MEMORY_OK \(sequence) \(total) \(available)"
      else { throw NativeControlFailure.framing }
      guard ContinuousClock.now < deadline else { throw NativeControlFailure.wireTimedOut }
      if command == "QUIT" { close() }
      return .init(sequence: sequence, capturedAt: capturedAt, total: total, available: available)
    } catch {
      close()
      throw error
    }
  }

  /// Retires the wire, not the guest process. Its owner still must reap it.
  public func close() {
    closed = true
    wire.close()
  }
}
