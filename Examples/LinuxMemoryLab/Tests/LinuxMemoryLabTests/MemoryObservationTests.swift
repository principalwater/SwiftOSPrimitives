import Foundation
import NativeLinuxVMM
import Testing

@testable import container_native_lab

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func memoryTelemetryProgressesDuringForegroundAllocation(refresh: Bool)
  async throws
{
  let input = NativeMemoryInput()
  let output = NativeMemoryOutput()
  let diagnostic = MemoryProbeSession(input: input, output: output, cpus: 2)
  let monitorInput = NativeMemoryInput()
  let monitorOutput = NativeMemoryOutput()
  let monitor = NativeMemorySession(input: monitorInput, output: monitorOutput)
  defer {
    input.finish()
    monitorInput.finish()
  }
  try output.write(Data("CANARY_READY 1000 900 cpus=2 packets=1 cpu0=1 cpu1=1\n".utf8))
  _ = try await diagnostic.start()
  try monitorOutput.write(Data("MEMORY_READY 1000 900\n".utf8))
  try await monitor.start()
  var wire = input.stream().makeAsyncIterator()
  var monitorWire = monitorInput.stream().makeAsyncIterator()
  let allocation = Task { try await diagnostic.observe("HOLD") }
  do {
    #expect(await wire.next() == Data("HOLD 1\n".utf8))
    let before = ContinuousClock.now
    let observation = Task {
      try await monitor.observeIfIdle(
        deadline: .now.advanced(by: .seconds(1)), refreshStatistics: refresh)
    }
    #expect(await monitorWire.next() == Data("\(refresh ? "OBS_REFRESH" : "OBS") 1\n".utf8))
    try monitorOutput.write(Data("MEMORY_OK 1 1000 500\n".utf8))
    let sample = try #require(try await observation.value)
    #expect(sample.sequence == 1 && sample.total == 1000 && sample.available == 500)
    #expect(sample.capturedAt >= before && sample.capturedAt <= ContinuousClock.now)
    #expect(try await diagnostic.observeIfIdle() == nil)
    try output.write(Data("CANARY_OK 1 1000 500 cpus=2 packets=2 cpu0=2 cpu1=2\n".utf8))
    #expect(try await allocation.value.sequence == 1)
    let quit = Task { try await monitor.quit() }
    #expect(await monitorWire.next() == Data("QUIT 2\n".utf8))
    try monitorOutput.write(Data("MEMORY_OK 2 1000 900\n".utf8))
    try await quit.value
    #expect(await monitorWire.next() == nil)
  } catch {
    await diagnostic.close()
    await monitor.close()
    allocation.cancel()
    _ = await allocation.result
    throw error
  }
  await diagnostic.close()
}

@Test(
  .timeLimit(.minutes(1)),
  arguments: [
    "MEMORY_OK 2 1000 900\n", "MEMORY_OK 01 1000 900\n",
    "MEMORY_OK 1 1000 1001\n", "MEMORY_OK 1 0 0\n",
    "MEMORY_OK  1 1000 900\n", "MEMORY_OK 1 01000 900\n",
    "MEMORY_OK 1 1000 900 \n",
  ]) func invalidMemoryTelemetryClosesWire(_ invalid: String) async throws
{
  let input = NativeMemoryInput()
  defer { input.finish() }
  let output = NativeMemoryOutput()
  let monitor = NativeMemorySession(input: input, output: output)
  try output.write(Data("MEMORY_READY 1000 900\n".utf8))
  try await monitor.start()
  var wire = input.stream().makeAsyncIterator()
  let pending = Task { try await monitor.observeIfIdle(deadline: .now.advanced(by: .seconds(1))) }
  #expect(await wire.next() == Data("OBS 1\n".utf8))
  try output.write(Data(invalid.utf8))
  await #expect(throws: NativeControlFailure.framing) { try await pending.value }
  await #expect(throws: NativeControlFailure.disconnected) {
    try await monitor.observeIfIdle(deadline: .now.advanced(by: .seconds(1)))
  }
  #expect(await wire.next() == nil)
}

@Test(arguments: [
  "MEMORY_READY  1000 900\n", "MEMORY_READY 1000 0900\n", "MEMORY_READY 1000 900 \n",
])
func noncanonicalMemoryReadinessCannotOpenTheSession(_ invalid: String) async throws {
  let input = NativeMemoryInput()
  defer { input.finish() }
  let output = NativeMemoryOutput()
  let monitor = NativeMemorySession(input: input, output: output)
  try output.write(Data(invalid.utf8))
  await #expect(throws: NativeControlFailure.framing) { try await monitor.start() }
  await monitor.close()
}

@Test(arguments: [false, true])
func aClosedMemoryWireCannotPublishLiveTelemetry(afterReadiness: Bool) async throws {
  let input = NativeMemoryInput()
  defer { input.finish() }
  let output = NativeMemoryOutput()
  let monitor = NativeMemorySession(input: input, output: output)
  try output.write(Data("MEMORY_READY 1000 900\n".utf8))
  if afterReadiness {
    try await monitor.start()
    // A peer may leave a syntactically valid reply queued before its EOF is observed.
    try output.write(Data("MEMORY_OK 1 1000 900\n".utf8))
  }
  output.close()
  if afterReadiness {
    await #expect(throws: NativeControlFailure.disconnected) {
      try await monitor.observeIfIdle(deadline: .now.advanced(by: .seconds(1)))
    }
  } else {
    await #expect(throws: NativeControlFailure.disconnected) { try await monitor.start() }
  }
  await monitor.close()
}

@Test(.timeLimit(.minutes(1)))
func aFinalQuitAcknowledgementSurvivesItsFollowingEOF() async throws {
  let input = NativeMemoryInput()
  defer { input.finish() }
  let output = NativeMemoryOutput()
  let monitor = NativeMemorySession(input: input, output: output)
  try output.write(Data("MEMORY_READY 1000 900\n".utf8))
  try await monitor.start()
  var wire = input.stream().makeAsyncIterator()
  let quitting = Task { try await monitor.quit() }
  #expect(await wire.next() == Data("QUIT 1\n".utf8))
  try output.write(Data("MEMORY_OK 1 1000 900\n".utf8))
  output.close()
  try await quitting.value
  #expect(await wire.next() == nil)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func abandonedMemoryTelemetryCannotConsumeLateReply(cancel: Bool) async throws {
  let input = NativeMemoryInput()
  defer { input.finish() }
  let output = NativeMemoryOutput()
  let monitor = NativeMemorySession(input: input, output: output)
  try output.write(Data("MEMORY_READY 1000 900\n".utf8))
  try await monitor.start()
  var wire = input.stream().makeAsyncIterator()
  let pending = Task {
    try await monitor.observeIfIdle(
      deadline: .now.advanced(by: cancel ? .seconds(5) : .milliseconds(50)))
  }
  #expect(await wire.next() == Data("OBS 1\n".utf8))
  if cancel {
    pending.cancel()
    await #expect(throws: CancellationError.self) { try await pending.value }
  } else {
    await #expect(throws: NativeControlFailure.wireTimedOut) { try await pending.value }
  }
  try output.write(Data("MEMORY_OK 1 1000 900\n".utf8))
  await #expect(throws: NativeControlFailure.disconnected) {
    try await monitor.observeIfIdle(deadline: .now.advanced(by: .seconds(1)))
  }
  #expect(await wire.next() == nil)
}

@Test(.timeLimit(.minutes(1))) func quiescentCanaryRetainsMemoryChecksWithoutInventingCPUWork()
  async throws
{
  let input = NativeMemoryInput()
  let output = NativeMemoryOutput()
  let session = MemoryProbeSession(input: input, output: output, cpus: 2)
  defer { input.finish() }
  try output.write(Data("CANARY_READY 1000 900 cpus=2 packets=1 cpu0=1 cpu1=1\n".utf8))
  _ = try await session.start()
  var wire = input.stream().makeAsyncIterator()
  for (sequence, command) in ["QUIESCE", "VERIFY", "QUIT"].enumerated() {
    let task = Task { try await session.observe(command) }
    #expect(await wire.next() == Data("\(command) \(sequence + 1)\n".utf8))
    try output.write(Data(
      "CANARY_OK \(sequence + 1) 1000 900 cpus=2 packets=1 cpu0=1 cpu1=1\n".utf8))
    #expect(try await task.value.sequence == UInt64(sequence + 1))
    if command == "QUIESCE" {
      for refused in ["QUIESCE", "HOLD", "DROP"] {
        await #expect(throws: NativeControlFailure.arguments) { try await session.observe(refused) }
      }
    }
  }
  #expect(await wire.next() == nil)
}
