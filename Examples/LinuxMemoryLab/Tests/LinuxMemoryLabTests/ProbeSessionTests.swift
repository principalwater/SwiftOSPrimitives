import Foundation
import NativeLinuxVMM
import Testing

@testable import container_native_lab

private func ready(_ output: NativeMemoryOutput) throws {
  try output.write(Data("CANARY_READY 1000 900 cpus=2 packets=1 cpu0=1 cpu1=1\n".utf8))
}

private func reply(_ output: NativeMemoryOutput, sequence: Int) throws {
  let n = sequence + 1
  try output.write(
    Data(
      "CANARY_OK \(sequence) 1000 900 cpus=2 packets=\(n) cpu0=\(n) cpu1=\(n)\n".utf8))
}

@Test(.timeLimit(.minutes(1))) func longLivedProbePreservesSequencesWithBoundedHistory()
  async throws
{
  let input = NativeMemoryInput()
  defer { input.finish() }
  let output = NativeMemoryOutput()
  let session = MemoryProbeSession(input: input, output: output, cpus: 2)
  try ready(output)
  _ = try await session.start()
  let peer = Task {
    var wire = input.stream().makeAsyncIterator()
    for sequence in 1...1100 {
      guard await wire.next() == Data("OBS \(sequence)\n".utf8) else {
        throw NativeControlFailure.framing
      }
      try reply(output, sequence: sequence)
    }
  }
  do {
    for sequence in 1...1100 {
      #expect(try await session.observe("OBS").sequence == UInt64(sequence))
    }
    try await peer.value
    #expect(await session.transcript.count <= 1025)
    #expect(await session.transcript.last?.hasPrefix("CANARY_OK 1100 ") == true)
  } catch {
    await session.close()
    peer.cancel()
    _ = await peer.result
    throw error
  }
  await session.close()
}

@Test func drainedProbeOutputHasNoCumulativeTrafficLimit() throws {
  let output = NativeMemoryOutput()
  let text = String(repeating: "x", count: 8000)
  for _ in 0..<256 {
    try output.write(Data((text + "\n").utf8))
    #expect(try output.takeLine() == text)
  }
  #expect(try output.takeLine() == nil)
  #expect(throws: NativeControlFailure.framing) { try output.write(Data(count: 16385)) }
}

@Test(.timeLimit(.minutes(1))) func passiveProbeSkipsBusyWireWithoutTakingSequence() async throws {
  let input = NativeMemoryInput()
  defer { input.finish() }
  let output = NativeMemoryOutput()
  let session = MemoryProbeSession(input: input, output: output, cpus: 2)
  try ready(output)
  _ = try await session.start()
  var wire = input.stream().makeAsyncIterator()
  let owner = Task { try await session.observe() }
  #expect(await wire.next() == Data("VERIFY 1\n".utf8))
  #expect(try await session.observeIfIdle() == nil)
  try reply(output, sequence: 1)
  #expect(try await owner.value.sequence == 1)
  let passive = Task { try await session.observeIfIdle() }
  #expect(await wire.next() == Data("OBS 2\n".utf8))
  try reply(output, sequence: 2)
  #expect(try await passive.value?.sequence == 2)
  await session.close()
  #expect(await wire.next() == nil)
}

@Test(.timeLimit(.minutes(1)), arguments: ["OBS", "OBS_REFRESH"])
func probeSerializesConcurrentTransactions(_ command: String) async throws {
  let input = NativeMemoryInput()
  defer { input.finish() }
  let output = NativeMemoryOutput()
  let session = MemoryProbeSession(input: input, output: output, cpus: 2)
  try ready(output)
  _ = try await session.start()
  var wire = input.stream().makeAsyncIterator()
  let first = Task { try await session.observe(command) }
  #expect(await wire.next() == Data("\(command) 1\n".utf8))
  let second = Task { try await session.observe() }
  try output.write(Data("CANARY_OK 1 1000 900 cpus=2 packets=1 cpu0=1 cpu1=1\n".utf8))
  #expect(await wire.next() == Data("VERIFY 2\n".utf8))
  try reply(output, sequence: 2)
  #expect(try await first.value.sequence == 1)
  #expect(try await second.value.sequence == 2)
  #expect(await session.transcript.count == 3)
  await session.close()
  #expect(await wire.next() == nil)
}

@Test(.timeLimit(.minutes(1))) func cancelledProbeCannotConsumeALateReply() async throws {
  let input = NativeMemoryInput()
  defer { input.finish() }
  let output = NativeMemoryOutput()
  let session = MemoryProbeSession(input: input, output: output, cpus: 2)
  try ready(output)
  _ = try await session.start()
  var wire = input.stream().makeAsyncIterator()
  let pending = Task { try await session.observe() }
  #expect(await wire.next() == Data("VERIFY 1\n".utf8))
  pending.cancel()
  await #expect(throws: CancellationError.self) { try await pending.value }
  try reply(output, sequence: 1)
  await #expect(throws: NativeControlFailure.disconnected) { try await session.observe() }
  #expect(await wire.next() == nil)
  #expect(await session.transcript.count == 1)
}

@Test(.timeLimit(.minutes(1))) func queuedCancellationDoesNotCloseCurrentOwner() async throws {
  let input = NativeMemoryInput()
  defer { input.finish() }
  let output = NativeMemoryOutput()
  let session = MemoryProbeSession(input: input, output: output, cpus: 2)
  try ready(output)
  _ = try await session.start()
  var wire = input.stream().makeAsyncIterator()
  let owner = Task { try await session.observe() }
  #expect(await wire.next() == Data("VERIFY 1\n".utf8))
  let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
  let queued = Task {
    entered.continuation.yield(())
    return try await session.observe()
  }
  var gate = entered.stream.makeAsyncIterator()
  _ = await gate.next()
  queued.cancel()
  await #expect(throws: CancellationError.self) { try await queued.value }
  entered.continuation.finish()
  try reply(output, sequence: 1)
  #expect(try await owner.value.sequence == 1)
  let next = Task { try await session.observe() }
  #expect(await wire.next() == Data("VERIFY 2\n".utf8))
  try reply(output, sequence: 2)
  #expect(try await next.value.sequence == 2)
  await session.close()
}

@Test(.timeLimit(.minutes(1))) func expiredQueueLeaseDoesNotWriteOrPoisonOwner() async throws {
  let input = NativeMemoryInput()
  defer { input.finish() }
  let output = NativeMemoryOutput()
  let session = MemoryProbeSession(input: input, output: output, cpus: 2)
  try ready(output)
  _ = try await session.start()
  var wire = input.stream().makeAsyncIterator()
  let owner = Task { try await session.observe() }
  #expect(await wire.next() == Data("VERIFY 1\n".utf8))
  await #expect(throws: NativeControlFailure.wireTimedOut) {
    try await session.observe(deadline: .now.advanced(by: .seconds(-1)))
  }
  try reply(output, sequence: 1)
  #expect(try await owner.value.sequence == 1)
  await session.close()
  #expect(await wire.next() == nil)
}

@Test(
  .timeLimit(.minutes(1)),
  arguments: [
    "CANARY_OK 2 1000 900 cpus=2 packets=2 cpu0=2 cpu1=2\n",
    "CANARY_OK 1 1000 900 cpus=2 packets=2 cpu0=2 cpu0=2\n",
    "CANARY_OK 1 1000 1001 cpus=2 packets=2 cpu0=2 cpu1=2\n",
  ]) func invalidProbeReplyClosesWire(_ invalid: String) async throws
{
  let input = NativeMemoryInput()
  defer { input.finish() }
  let output = NativeMemoryOutput()
  let session = MemoryProbeSession(input: input, output: output, cpus: 2)
  try ready(output)
  _ = try await session.start()
  var wire = input.stream().makeAsyncIterator()
  let pending = Task { try await session.observe() }
  #expect(await wire.next() == Data("VERIFY 1\n".utf8))
  try output.write(Data(invalid.utf8))
  await #expect(throws: NativeControlFailure.framing) { try await pending.value }
  await #expect(throws: NativeControlFailure.disconnected) { try await session.observe() }
  #expect(await wire.next() == nil)
}

@Test(.timeLimit(.minutes(1))) func silentProbeDeadlineClosesWire() async throws {
  let input = NativeMemoryInput()
  defer { input.finish() }
  let output = NativeMemoryOutput()
  let session = MemoryProbeSession(input: input, output: output, cpus: 2)
  try ready(output)
  _ = try await session.start()
  var wire = input.stream().makeAsyncIterator()
  let pending = Task {
    try await session.observe(deadline: .now.advanced(by: .milliseconds(50)))
  }
  #expect(await wire.next() == Data("VERIFY 1\n".utf8))
  await #expect(throws: NativeControlFailure.wireTimedOut) { try await pending.value }
  try reply(output, sequence: 1)
  await #expect(throws: NativeControlFailure.disconnected) { try await session.observe() }
  #expect(await wire.next() == nil)
  #expect(await session.transcript.count == 1)
}
