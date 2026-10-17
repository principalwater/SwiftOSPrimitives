import Foundation

/// One transactional wire; concrete process owners decide how its IO is retired.
protocol MemorySessionWire: Sendable {
  func send(_ data: Data, until deadline: ContinuousClock.Instant) async throws
  func takeLine(allowAfterClose: Bool) throws -> String?
  func close()
}

/// The existing ReaderStream/Writer path remains the diagnostic exec adapter.
private final class MemoryChannelWire: MemorySessionWire {
  let input: NativeMemoryInput
  let output: NativeMemoryOutput

  init(input: NativeMemoryInput, output: NativeMemoryOutput) {
    self.input = input
    self.output = output
  }

  func send(_ data: Data, until deadline: ContinuousClock.Instant) async throws {
    try Task.checkCancellation()
    guard ContinuousClock.now < deadline else { throw NativeControlFailure.wireTimedOut }
    try input.send(data)
  }

  func takeLine(allowAfterClose: Bool) throws -> String? {
    try output.takeLine(allowAfterClose: allowAfterClose)
  }

  func close() { input.finish() }
}

extension NativeMemorySession {
  /// The caller still owns the guest process; retiring a channel never reaps it.
  public init(
    input: NativeMemoryInput, output: NativeMemoryOutput, maximumGuestBytes: UInt64
  ) throws {
    try self.init(
      wire: MemoryChannelWire(input: input, output: output), maximumGuestBytes: maximumGuestBytes)
  }
}
