import Foundation
import Testing

@testable import container_native_lab

private func ready(_ output: ProbeOutput) throws {
  try output.write(Data("CANARY_READY 1000 900 cpus=2 packets=1 cpu0=1 cpu1=1\n".utf8))
}

private func reply(_ output: ProbeOutput, sequence: Int) throws {
  let n = sequence + 1
  try output.write(Data(
    "CANARY_OK \(sequence) 1000 900 cpus=2 packets=\(n) cpu0=\(n) cpu1=\(n)\n".utf8))
}

@Test(.timeLimit(.minutes(1))) func passiveProbeSkipsBusyWireWithoutTakingSequence() async throws {
  let input = CommandInput()
  defer { input.finish() }
  let output = ProbeOutput()
  let session = MemoryProbeSession(input: input, output: output, cpus: 2, began: .now)
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

@Test(.timeLimit(.minutes(1))) func probeSerializesConcurrentTransactions() async throws {
  let input = CommandInput()
  defer { input.finish() }
  let output = ProbeOutput()
  let session = MemoryProbeSession(input: input, output: output, cpus: 2, began: .now)
  try ready(output)
  _ = try await session.start()
  var wire = input.stream().makeAsyncIterator()
  let first = Task { try await session.observe("OBS") }
  #expect(await wire.next() == Data("OBS 1\n".utf8))
  let second = Task { try await session.observe() }
  try reply(output, sequence: 1)
  #expect(await wire.next() == Data("VERIFY 2\n".utf8))
  try reply(output, sequence: 2)
  #expect(try await first.value.sequence == 1)
  #expect(try await second.value.sequence == 2)
  #expect(await session.transcript.count == 3)
  await session.close()
  #expect(await wire.next() == nil)
}

@Test(.timeLimit(.minutes(1))) func cancelledProbeCannotConsumeALateReply() async throws {
  let input = CommandInput()
  defer { input.finish() }
  let output = ProbeOutput()
  let session = MemoryProbeSession(input: input, output: output, cpus: 2, began: .now)
  try ready(output)
  _ = try await session.start()
  var wire = input.stream().makeAsyncIterator()
  let pending = Task { try await session.observe() }
  #expect(await wire.next() == Data("VERIFY 1\n".utf8))
  pending.cancel()
  await #expect(throws: CancellationError.self) { try await pending.value }
  try reply(output, sequence: 1)
  await #expect(throws: LabFailure.disconnected) { try await session.observe() }
  #expect(await wire.next() == nil)
  #expect(await session.transcript.count == 1)
}

@Test(.timeLimit(.minutes(1))) func queuedCancellationDoesNotCloseCurrentOwner() async throws {
  let input = CommandInput()
  defer { input.finish() }
  let output = ProbeOutput()
  let session = MemoryProbeSession(input: input, output: output, cpus: 2, began: .now)
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
  let input = CommandInput()
  defer { input.finish() }
  let output = ProbeOutput()
  let session = MemoryProbeSession(input: input, output: output, cpus: 2, began: .now)
  try ready(output)
  _ = try await session.start()
  var wire = input.stream().makeAsyncIterator()
  let owner = Task { try await session.observe() }
  #expect(await wire.next() == Data("VERIFY 1\n".utf8))
  await #expect(throws: LabFailure.deadline) {
    try await session.observe(deadline: .now.advanced(by: .seconds(-1)))
  }
  try reply(output, sequence: 1)
  #expect(try await owner.value.sequence == 1)
  await session.close()
  #expect(await wire.next() == nil)
}

@Test(.timeLimit(.minutes(1)), arguments: [
  "CANARY_OK 2 1000 900 cpus=2 packets=2 cpu0=2 cpu1=2\n",
  "CANARY_OK 1 1000 900 cpus=2 packets=2 cpu0=2 cpu0=2\n",
  "CANARY_OK 1 1000 1001 cpus=2 packets=2 cpu0=2 cpu1=2\n",
]) func invalidProbeReplyClosesWire(_ invalid: String) async throws {
  let input = CommandInput()
  defer { input.finish() }
  let output = ProbeOutput()
  let session = MemoryProbeSession(input: input, output: output, cpus: 2, began: .now)
  try ready(output)
  _ = try await session.start()
  var wire = input.stream().makeAsyncIterator()
  let pending = Task { try await session.observe() }
  #expect(await wire.next() == Data("VERIFY 1\n".utf8))
  try output.write(Data(invalid.utf8))
  await #expect(throws: LabFailure.framing) { try await pending.value }
  await #expect(throws: LabFailure.disconnected) { try await session.observe() }
  #expect(await wire.next() == nil)
}

@Test(.timeLimit(.minutes(1))) func silentProbeDeadlineClosesWire() async throws {
  let input = CommandInput()
  defer { input.finish() }
  let output = ProbeOutput()
  let session = MemoryProbeSession(input: input, output: output, cpus: 2, began: .now)
  try ready(output)
  _ = try await session.start()
  var wire = input.stream().makeAsyncIterator()
  let pending = Task {
    try await session.observe(deadline: .now.advanced(by: .milliseconds(50)))
  }
  #expect(await wire.next() == Data("VERIFY 1\n".utf8))
  await #expect(throws: LabFailure.deadline) { try await pending.value }
  try reply(output, sequence: 1)
  await #expect(throws: LabFailure.disconnected) { try await session.observe() }
  #expect(await wire.next() == nil)
  #expect(await session.transcript.count == 1)
}
