import Darwin
import Foundation
import Testing

@testable import NativeLinuxVMM

private func awaitReadiness(_ condition: @Sendable () -> Bool) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(3))
  while !condition() {
    guard ContinuousClock.now < deadline else { throw NativeFailure.deadline }
    try await Task.sleep(for: .milliseconds(1))
  }
}

@Test(.timeLimit(.minutes(1)))
func asyncEthernetReceiverPreservesDatagramsAcrossRearming() async throws {
  let link = try IsolatedNetwork()
  let device = try link.claim()
  defer {
    _ = Darwin.close(device)
    try? link.close()
  }
  let (acknowledgements, acknowledge) = AsyncStream<Int>.makeStream(
    bufferingPolicy: .bufferingOldest(1))
  let expected = (0..<32).map { Data(repeating: UInt8($0), count: 14 + $0 * 47) }
  let receiver = Task {
    var frames: [Data] = []
    for index in expected.indices {
      frames.append(try await link.receivePacket())
      acknowledge.yield(index)
    }
    acknowledge.finish()
    return frames
  }
  defer { receiver.cancel() }
  var iterator = acknowledgements.makeAsyncIterator()
  for index in expected.indices {
    try await awaitReadiness { link.receiveStatus.waiting }
    #expect(try IsolatedNetwork.transmit(expected[index], descriptor: device))
    #expect(await iterator.next() == index)
  }
  #expect(try await receiver.value == expected)
  #expect(link.receiveStatus.readinessEvents == 32)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func stoppingAsyncEthernetReceiverDoesNotRetireTheCable(beforeWait: Bool) async throws {
  let link = try IsolatedNetwork()
  let device = try link.claim()
  defer {
    _ = Darwin.close(device)
    try? link.close()
  }
  if beforeWait { link.stopReceiving() }
  let receiver = Task { try await link.receivePacket() }
  if !beforeWait { try await awaitReadiness { link.receiveStatus.waiting } }
  link.stopReceiving()
  link.stopReceiving()
  await #expect(throws: CancellationError.self) { try await receiver.value }
  if !beforeWait {
    try await awaitReadiness { link.receiveStatus.descriptorCloseStatus != nil }
    #expect(link.receiveStatus.descriptorCloseStatus == 0)
  }
  let frame = Data(repeating: 42, count: 1514)
  #expect(try IsolatedNetwork.transmit(frame, descriptor: device))
  #expect(try link.receive() == frame)
  #expect(try link.send(frame))
  #expect(try IsolatedNetwork.receive(descriptor: device) == frame)
}

@Test(.timeLimit(.minutes(1)))
func asyncEthernetCancellationReleasesAWaitingReceiver() async throws {
  for _ in 0..<32 {
    let link = try IsolatedNetwork()
    let receiver = Task { try await link.receivePacket() }
    try await awaitReadiness { link.receiveStatus.waiting }
    receiver.cancel()
    await #expect(throws: CancellationError.self) { try await receiver.value }
    #expect(link.receiveStatus.retired)
    try await awaitReadiness { link.receiveStatus.descriptorCloseStatus != nil }
    #expect(link.receiveStatus.descriptorCloseStatus == 0)
    try link.close()
  }
}

@Test(.timeLimit(.minutes(1)))
func packetReadinessReevaluatesQueuedDataWithoutSpinning() async throws {
  let link = try IsolatedNetwork()
  let device = try link.claim()
  let readiness = try PacketReadiness(descriptor: device)
  defer {
    readiness.cancel()
    _ = Darwin.close(device)
    try? link.close()
  }
  let first = Task { try await readiness.wait() }
  defer { first.cancel() }
  try await awaitReadiness { readiness.status.waiting }
  let frame = Data(repeating: 7, count: 1514)
  #expect(try link.send(frame))
  try await first.value
  #expect(readiness.status.events == 1)
  // A measurement window: the datagram stays unread throughout, not a scheduling delay.
  try await Task.sleep(for: .milliseconds(50))
  #expect(readiness.status.events == 1)
  try await readiness.wait()
  #expect(readiness.status.events == 2)
  #expect(try IsolatedNetwork.receive(descriptor: device) == frame)
  readiness.cancel()
  try await awaitReadiness { readiness.status.closeStatus != nil }
  #expect(readiness.status.closeStatus == 0)
}

@Test(.timeLimit(.minutes(1)))
func rejectedReceiverCannotRetireAnAdmittedReceiver() async throws {
  let link = try IsolatedNetwork()
  let device = try link.claim()
  defer {
    _ = Darwin.close(device)
    try? link.close()
  }
  let admitted = Task { try await link.receivePacket() }
  defer { admitted.cancel() }
  try await awaitReadiness { link.receiveStatus.waiting }
  let rejected = Task { try await link.receivePacket() }
  await #expect {
    try await rejected.value
  } throws: { error in
    if case NativeFailure.state = error { return true }
    return false
  }
  rejected.cancel()
  #expect(!link.receiveStatus.retired && link.receiveStatus.waiting)
  let frame = Data(repeating: 1, count: 14)
  #expect(try IsolatedNetwork.transmit(frame, descriptor: device))
  #expect(try await admitted.value == frame)
}

@Test(.timeLimit(.minutes(1)))
func cancellationBeforeAdmissionDoesNotAcquireReceiverAuthority() async throws {
  let link = try IsolatedNetwork()
  let device = try link.claim()
  defer {
    _ = Darwin.close(device)
    try? link.close()
  }
  let (gate, release) = AsyncStream<Void>.makeStream()
  let cancelled = Task {
    for await _ in gate { break }
    return try await link.receivePacket()
  }
  cancelled.cancel()
  release.finish()
  await #expect(throws: CancellationError.self) { try await cancelled.value }
  #expect(!link.receiveStatus.retired)
  let admitted = Task { try await link.receivePacket() }
  defer { admitted.cancel() }
  try await awaitReadiness { link.receiveStatus.waiting }
  let frame = Data(repeating: 2, count: 14)
  #expect(try IsolatedNetwork.transmit(frame, descriptor: device))
  #expect(try await admitted.value == frame)
}

@Test func unarmedPacketReadinessHasNoOwnerRetainCycle() throws {
  let link = try IsolatedNetwork()
  let device = try link.claim()
  defer {
    _ = Darwin.close(device)
    try? link.close()
  }
  weak var released: PacketReadiness?
  do {
    let readiness = try PacketReadiness(descriptor: device)
    released = readiness
  }
  #expect(released == nil)
}

@Test(.timeLimit(.minutes(1)))
func packetRegistrationCannotFollowAReplacedCallerDescriptor() async throws {
  let link = try IsolatedNetwork()
  let device = try link.claim()
  let original = fcntl(device, F_DUPFD_CLOEXEC, 3)
  try #require(original >= 0)
  let replacement = try IsolatedNetwork(index: 1)
  let other = try replacement.claim()
  let readiness = try PacketReadiness(descriptor: device)
  defer {
    readiness.cancel()
    _ = Darwin.close(original)
    _ = Darwin.close(device)
    _ = Darwin.close(other)
    try? link.close()
    try? replacement.close()
  }
  // Atomically replace only this test's still-owned descriptor; never target a freed FD number.
  try #require(dup2(other, device) == device)
  let wait = Task { try await readiness.wait() }
  defer { wait.cancel() }
  try await awaitReadiness { readiness.status.waiting }
  let newFrame = Data(repeating: 2, count: 42)
  #expect(try replacement.send(newFrame))
  try await Task.sleep(for: .milliseconds(50))
  #expect(readiness.status.events == 0 && readiness.status.waiting)
  let oldFrame = Data(repeating: 1, count: 42)
  #expect(try link.send(oldFrame))
  try await wait.value
  #expect(try IsolatedNetwork.receive(descriptor: original) == oldFrame)
  #expect(try IsolatedNetwork.receive(descriptor: device) == newFrame)
  readiness.cancel()
  try await awaitReadiness { readiness.status.closeStatus != nil }
  #expect(readiness.status.closeStatus == 0)
  #expect(try replacement.send(newFrame))
  #expect(try IsolatedNetwork.receive(descriptor: device) == newFrame)
}
