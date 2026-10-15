import Containerization
import Foundation
import Synchronization

enum LabFailure: Error, Equatable { case arguments, framing, disconnected, deadline, invariant }

final class CommandInput: ReaderStream {
  private let values: AsyncStream<Data>
  private let continuation: AsyncStream<Data>.Continuation
  init() {
    (values, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(1))
  }
  func stream() -> AsyncStream<Data> { values }
  func send(_ data: Data) throws {
    guard data.count <= 64 else { throw LabFailure.framing }
    guard case .enqueued = continuation.yield(data) else { throw LabFailure.disconnected }
  }
  func finish() { continuation.finish() }
}

final class ProbeOutput: Writer {
  private struct State {
    var bytes = Data()
    var total = 0
    var closed = false
  }
  private let state = Mutex(State())
  func write(_ data: Data) throws {
    try state.withLock { state in
      guard !state.closed, data.count <= 16384 - state.bytes.count,
        data.count <= 1024 * 1024 - state.total
      else { throw LabFailure.framing }
      state.bytes.append(data)
      state.total += data.count
    }
  }
  func close() { state.withLock { $0.closed = true } }
  func takeLine() throws -> String? {
    try state.withLock { state in
      if let newline = state.bytes.firstIndex(of: 10) {
        let line = state.bytes[..<newline]
        guard line.count <= 8192, line.allSatisfy({ $0 >= 32 && $0 <= 126 }) else {
          throw LabFailure.framing
        }
        let text = String(decoding: line, as: UTF8.self)
        state.bytes.removeSubrange(...newline)
        return text
      }
      guard state.bytes.count <= 8192 else { throw LabFailure.framing }
      guard !state.closed else { throw LabFailure.disconnected }
      return nil
    }
  }
}

struct ProbeObservation {
  let sequence: UInt64
  let capturedAtNanoseconds: UInt64
  let total: UInt64
  let available: UInt64
  let residentPages: UInt64
  let rss: UInt64
  let requestedPFNs: UInt32
  let actualPFNs: UInt32
}

/// One serial owner per endpoint; stream identity is never inferred from a global PID.
@MainActor final class ProbeChannel {
  private let input: CommandInput
  private let output: ProbeOutput
  private let began: ContinuousClock.Instant
  private(set) var sequence: UInt64 = 0
  private(set) var transcript: [String] = []
  init(input: CommandInput, output: ProbeOutput, began: ContinuousClock.Instant) {
    self.input = input
    self.output = output
    self.began = began
  }
  var now: UInt64 {
    let value = began.duration(to: .now).components
    return UInt64(value.seconds) * 1_000_000_000 + UInt64(value.attoseconds / 1_000_000_000)
  }
  private func line() async throws -> String {
    let end = ContinuousClock.now.advanced(by: .seconds(3))
    while ContinuousClock.now < end {
      try Task.checkCancellation()
      if let text = try output.takeLine() {
        transcript.append(text)
        return text
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw LabFailure.deadline
  }
  func ready(expectedDriver: String) async throws {
    let words = try await line().split(separator: " ")
    guard words.count == 5, words[0] == "PROBE_READY", words[1] == "4096",
      let total = UInt64(words[2]), let available = UInt64(words[3]), available <= total,
      expectedDriver == "bound:" ? words[4].hasPrefix(expectedDriver) : words[4] == expectedDriver
    else { throw LabFailure.framing }
    if expectedDriver == "bound:" {
      let bits = words[4].dropFirst(expectedDriver.count)
      guard (64...256).contains(bits.count), bits.allSatisfy({ $0 == "0" || $0 == "1" }) else {
        throw LabFailure.framing
      }
    }
  }
  private func send(_ command: String) throws {
    guard sequence < 1000 else { throw LabFailure.framing }
    sequence += 1
    let data = Data("\(command) \(sequence)\n".utf8)
    try input.send(data)
  }
  func observe(_ command: String) async throws -> ProbeObservation {
    let captured = now
    try send(command)
    let words = try await line().split(separator: " ")
    guard words.count == 8, words[0] == "PROBE_OBS",
      UInt64(words[1]) == sequence, let total = UInt64(words[2]),
      let available = UInt64(words[3]), available <= total,
      let pages = UInt64(words[4]), pages <= 22528, let rss = UInt64(words[5]),
      let requested = UInt32(words[6]), let actual = UInt32(words[7])
    else { throw LabFailure.framing }
    return .init(
      sequence: sequence, capturedAtNanoseconds: captured, total: total,
      available: available, residentPages: pages, rss: rss,
      requestedPFNs: requested, actualPFNs: actual)
  }
  func quit() async throws {
    try send("Q")
    guard try await line() == "PROBE_DONE \(sequence)" else { throw LabFailure.framing }
  }
  func verifyWorkloadLimitsAndMount() async throws {
    try send("I")
    let words = try await line().split(separator: " ")
    guard words.count == 7, words[0] == "PROBE_INFO", UInt64(words[1]) == sequence,
      UInt64(words[2]) == 128 << 20, let capabilities = UInt64(words[3], radix: 16),
      capabilities & ((1 << 17) | (1 << 21)) == 0,
      words[4] == "1", words[5] == "0", words[6] == "0"
    else { throw LabFailure.invariant }
  }
  func close() { input.finish() }
}
