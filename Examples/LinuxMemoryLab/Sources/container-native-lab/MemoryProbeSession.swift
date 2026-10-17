import BoundedMemory
import Foundation
import NativeLinuxVMM

/// The wire has no multiplexing: one lease covers send through validated reply.
actor MemoryProbeSession {
  typealias Observation = NativeMemoryObservation
  struct Load: Sendable {
    let sequence: UInt64
    let count: Int
    let bytes: UInt64
  }
  private let input: NativeMemoryInput
  private let output: NativeMemoryOutput
  private let cpus: Int
  private var sequence: UInt64 = 0
  private var busy = false
  private var waiting = 0
  private var closed = false
  private var ready = false
  private var quiesced = false
  private var seenWork: [UInt64]
  private var checkedWork: [UInt64]
  private var seenPackets: UInt64 = 0
  private var checkedPackets: UInt64 = 0
  private var history = RecentHistory<String>(capacity: 1025)
  var transcript: [String] { history.elements }
  var transcriptTotal: UInt64 { history.totalCount }
  var transcriptDropped: UInt64 { history.droppedCount }

  init(input: NativeMemoryInput, output: NativeMemoryOutput, cpus: Int) {
    self.input = input
    self.output = output
    self.cpus = cpus
    seenWork = Array(repeating: 0, count: cpus)
    checkedWork = Array(repeating: 0, count: cpus)
  }
  private func acquire(
    until deadline: ContinuousClock.Instant, wait: Bool = true
  ) async throws -> Bool {
    try Task.checkCancellation()
    guard !closed else { throw NativeControlFailure.disconnected }
    guard ContinuousClock.now < deadline else { throw NativeControlFailure.wireTimedOut }
    if busy, !wait { return false }
    guard waiting < 2 else { throw NativeControlFailure.invariant }
    waiting += 1
    defer { waiting -= 1 }
    // shortcut: two finite lab callers; replace with a queued permit for interactive clients.
    while busy {
      try Task.checkCancellation()
      guard !closed else { throw NativeControlFailure.disconnected }
      guard ContinuousClock.now < deadline else { throw NativeControlFailure.wireTimedOut }
      try await Task.sleep(for: .milliseconds(5))
    }
    try Task.checkCancellation()
    guard !closed else { throw NativeControlFailure.disconnected }
    guard ContinuousClock.now < deadline else { throw NativeControlFailure.wireTimedOut }
    busy = true
    return true
  }
  private func line(until deadline: ContinuousClock.Instant) async throws -> String {
    while ContinuousClock.now < deadline {
      try Task.checkCancellation()
      guard !closed else { throw NativeControlFailure.disconnected }
      if let text = try output.takeLine() {
        try history.append(text)
        return text
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw NativeControlFailure.wireTimedOut
  }
  private func checkWork(_ fields: ArraySlice<Substring>, progress: Bool) throws {
    var values: [String: UInt64] = [:]
    for field in fields {
      let pair = field.split(separator: "=")
      guard pair.count == 2, let n = UInt64(pair[1]), values[String(pair[0])] == nil else {
        throw NativeControlFailure.framing
      }
      values[String(pair[0])] = n
    }
    guard values.count == cpus + 2, values["cpus"] == UInt64(cpus),
      let packets = values["packets"], packets >= seenPackets,
      !progress || packets > checkedPackets
    else { throw NativeControlFailure.invariant }
    var work: [UInt64] = []
    for core in 0..<cpus {
      guard let n = values["cpu\(core)"], n >= seenWork[core],
        !progress || n > checkedWork[core]
      else { throw NativeControlFailure.invariant }
      work.append(n)
    }
    seenWork = work
    seenPackets = packets
    if progress {
      checkedWork = work
      checkedPackets = packets
    }
  }
  func start() async throws -> Observation {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    _ = try await acquire(until: deadline)
    defer { busy = false }
    do {
      guard !ready else { throw NativeControlFailure.invariant }
      let capturedAt = ContinuousClock.now
      let words = try await line(until: deadline).split(separator: " ")
      guard words.count == 5 + cpus, words[0] == "CANARY_READY",
        let total = UInt64(words[1]), let available = UInt64(words[2]), available <= total
      else { throw NativeControlFailure.framing }
      try checkWork(words.dropFirst(3), progress: true)
      ready = true
      return .init(sequence: 0, capturedAt: capturedAt, total: total, available: available)
    } catch {
      close()
      throw error
    }
  }
  private func send(_ command: String, suffix: String = "") throws -> UInt64 {
    guard ready, sequence < UInt64.max else { throw NativeControlFailure.framing }
    sequence += 1
    try input.send(Data("\(command) \(sequence)\(suffix)\n".utf8))
    return sequence
  }
  func observe(
    _ command: String = "VERIFY",
    deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(5))
  ) async throws -> Observation {
    guard ["VERIFY", "OBS", "OBS_REFRESH", "HOLD", "DROP", "QUIESCE", "QUIT"].contains(command) else {
      throw NativeControlFailure.arguments
    }
    _ = try await acquire(until: deadline)
    return try await observation(command, deadline: deadline)
  }
  /// Passive sampling never waits behind a foreground memory scan.
  func observeIfIdle(
    deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(3))
  ) async throws -> Observation? {
    guard try await acquire(until: deadline, wait: false) else { return nil }
    return try await observation("OBS", deadline: deadline)
  }
  private func observation(
    _ command: String, deadline: ContinuousClock.Instant
  ) async throws -> Observation {
    defer { busy = false }
    guard !quiesced || ["VERIFY", "OBS", "OBS_REFRESH", "QUIT"].contains(command) else {
      throw NativeControlFailure.arguments
    }
    do {
      let capturedAt = ContinuousClock.now
      let sent = try send(command)
      let words = try await line(until: deadline).split(separator: " ")
      try Task.checkCancellation()
      guard !closed, words.count == 6 + cpus, words[0] == "CANARY_OK",
        UInt64(words[1]) == sent, let total = UInt64(words[2]),
        let available = UInt64(words[3]), available <= total
      else { throw NativeControlFailure.framing }
      try checkWork(words.dropFirst(4),
        progress: !quiesced && command != "QUIESCE" && command != "OBS" && command != "OBS_REFRESH")
      if command == "QUIESCE" { quiesced = true }
      if command == "QUIT" { close() }
      return .init(sequence: sent, capturedAt: capturedAt, total: total, available: available)
    } catch {
      close()
      throw error
    }
  }
  func load(cycle: Int) async throws -> Load {
    guard (1...2).contains(cycle) else { throw NativeControlFailure.arguments }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    _ = try await acquire(until: deadline)
    defer { busy = false }
    do {
      let sent = try send("STATE", suffix: " \(cycle)")
      let words = try await line(until: deadline).split(separator: " ")
      try Task.checkCancellation()
      guard !closed, words.count == 4, words[0] == "LOAD_STATE", UInt64(words[1]) == sent,
        let count = Int(words[2]), (0...1).contains(count), let bytes = UInt64(words[3])
      else { throw NativeControlFailure.framing }
      return .init(sequence: sent, count: count, bytes: bytes)
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
