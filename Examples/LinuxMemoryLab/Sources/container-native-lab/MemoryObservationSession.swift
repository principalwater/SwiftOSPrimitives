import Foundation

struct GuestMemoryObservation: Sendable {
  let sequence: UInt64
  let capturedAt: UInt64
  let total: UInt64
  let available: UInt64
}

/// A separate process and wire keep allocation diagnostics from blocking memory observations.
actor MemoryObservationSession {
  private let input: CommandInput
  private let output: ProbeOutput
  private let began: ContinuousClock.Instant
  private var sequence: UInt64 = 0
  private var ready = false
  private var busy = false
  private var closed = false

  init(input: CommandInput, output: ProbeOutput, began: ContinuousClock.Instant) {
    precondition(began <= .now)
    self.input = input
    self.output = output
    self.began = began
  }

  private var now: UInt64 {
    let value = began.duration(to: .now).components
    return UInt64(value.seconds) * 1_000_000_000 + UInt64(value.attoseconds / 1_000_000_000)
  }

  private func line(until deadline: ContinuousClock.Instant) async throws -> String {
    while ContinuousClock.now < deadline {
      try Task.checkCancellation()
      guard !closed else { throw LabFailure.disconnected }
      if let text = try output.takeLine() { return text }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw LabFailure.deadline
  }

  func start() async throws {
    guard !ready, !busy, !closed else { throw LabFailure.invariant }
    busy = true
    defer { busy = false }
    do {
      let words = try await line(until: .now.advanced(by: .seconds(5))).split(separator: " ")
      guard words.count == 3, words[0] == "MEMORY_READY", let total = UInt64(words[1]),
        total > 0, let available = UInt64(words[2]), available <= total
      else { throw LabFailure.framing }
      ready = true
    } catch {
      close()
      throw error
    }
  }

  func observeIfIdle(deadline: ContinuousClock.Instant) async throws -> GuestMemoryObservation? {
    try Task.checkCancellation()
    guard ready, !closed else { throw LabFailure.disconnected }
    guard !busy else { return nil }
    return try await exchange("OBS", deadline: deadline)
  }

  func quit() async throws {
    guard ready, !busy, !closed else { throw LabFailure.disconnected }
    _ = try await exchange("QUIT", deadline: .now.advanced(by: .seconds(5)))
  }

  private func exchange(_ command: String, deadline: ContinuousClock.Instant) async throws
    -> GuestMemoryObservation
  {
    guard ContinuousClock.now < deadline else { throw LabFailure.deadline }
    busy = true
    defer { busy = false }
    do {
      guard sequence < UInt64.max else { throw LabFailure.invariant }
      sequence += 1
      let capturedAt = now
      try input.send(Data("\(command) \(sequence)\n".utf8))
      let words = try await line(until: deadline).split(separator: " ")
      try Task.checkCancellation()
      guard !closed, words.count == 4, words[0] == "MEMORY_OK",
        words[1] == Substring(String(sequence)), let total = UInt64(words[2]), total > 0,
        let available = UInt64(words[3]), available <= total
      else { throw LabFailure.framing }
      if command == "QUIT" { close() }
      return .init(sequence: sequence, capturedAt: capturedAt, total: total, available: available)
    } catch {
      close()
      throw error
    }
  }

  func close() {
    closed = true
    input.finish()
  }
}
