import Darwin
import Foundation
import Testing

@testable import NativeLinuxVMM

private final class MemorySockets: Sendable {
  let sources: [FileHandle]
  let peers: [FileHandle]

  init(errorType: Int32 = SOCK_STREAM) throws {
    var sources: [FileHandle] = []
    var peers: [FileHandle] = []
    for index in 0..<3 {
      var pair: [Int32] = [-1, -1]
      guard socketpair(AF_UNIX, index == 2 ? errorType : SOCK_STREAM, 0, &pair) == 0 else {
        throw MemorySocketFailure.system("test-pair", errno)
      }
      sources.append(FileHandle(fileDescriptor: pair[0], closeOnDealloc: true))
      peers.append(FileHandle(fileDescriptor: pair[1], closeOnDealloc: true))
      for fd in pair {
        var one: Int32 = 1
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
          setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, 4) == 0
        else { throw MemorySocketFailure.system("test-flags", errno) }
      }
    }
    self.sources = sources
    self.peers = peers
  }

  func wire() throws -> MemorySocketWire {
    try MemorySocketWire(input: sources[0], output: sources[1], error: sources[2])
  }

  func closeSources() throws {
    for handle in sources { try handle.close() }
  }

  func fillInput() throws {
    let fd = sources[0].fileDescriptor
    var capacity: Int32 = 4096
    guard setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &capacity, 4) == 0 else {
      throw MemorySocketFailure.system("test-buffer", errno)
    }
    let bytes = [UInt8](repeating: 0x46, count: 4096)
    var filled = 0
    while filled < 4 << 20 {
      let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
      if count > 0 { filled += count; continue }
      if count < 0, errno == EINTR { continue }
      if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
        try #require(filled > 0)
        return
      }
      throw MemorySocketFailure.system("test-fill", errno)
    }
    throw NativeControlFailure.invariant
  }
}

private func sendPeer(_ text: String, to peer: FileHandle) async throws {
  let bytes = Data(text.utf8)
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  var offset = 0
  while offset < bytes.count {
    try Task.checkCancellation()
    guard ContinuousClock.now < deadline else { throw NativeControlFailure.wireTimedOut }
    let count = bytes.withUnsafeBytes {
      Darwin.write(peer.fileDescriptor, $0.baseAddress! + offset, $0.count - offset)
    }
    if count > 0 { offset += count; continue }
    if count < 0, errno == EINTR { continue }
    guard count < 0, errno == EAGAIN || errno == EWOULDBLOCK else {
      throw MemorySocketFailure.system("test-send", errno)
    }
    try await Task.sleep(for: .milliseconds(1))
  }
}

private func receivePeerLine(_ peer: FileHandle) async throws -> String {
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  var bytes = Data()
  while ContinuousClock.now < deadline {
    let count = try withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 128) { buffer in
      let count = Darwin.read(peer.fileDescriptor, buffer.baseAddress!, buffer.count)
      if count > 0 { bytes.append(buffer.baseAddress!, count: count) }
      if count < 0, errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
        throw MemorySocketFailure.system("test-receive", errno)
      }
      return count
    }
    try #require(bytes.count <= 128 && count != 0)
    if bytes.last == 10 { return String(decoding: bytes, as: UTF8.self) }
    try await Task.sleep(for: .milliseconds(1))
  }
  throw NativeControlFailure.wireTimedOut
}

private func expectPeerEOF(_ peer: FileHandle) {
  var byte: UInt8 = 0
  #expect(Darwin.read(peer.fileDescriptor, &byte, 1) == 0)
}

@Test(.timeLimit(.minutes(1)))
func nativeMemorySocketPreservesPartialFramesAndRetiresAllOwnedDuplicates() async throws {
  let sockets = try MemorySockets()
  let wire = try sockets.wire()
  defer { wire.close() }
  try sockets.closeSources()
  try await sendPeer("MEMORY_REA", to: sockets.peers[1])
  #expect(try wire.takeLine(allowAfterClose: false) == nil)
  try await sendPeer("DY 1000 900\n", to: sockets.peers[1])
  let session = try NativeMemorySession(wire: wire, maximumGuestBytes: 1000)
  try await session.start()
  let observation = Task {
    try await session.observeIfIdle(deadline: .now.advanced(by: .seconds(5)))
  }
  do {
    #expect(try await receivePeerLine(sockets.peers[0]) == "OBS 1\n")
    try await sendPeer("MEMORY_OK 1 1000 500\n", to: sockets.peers[1])
    let reading = try #require(try await observation.value)
    #expect(reading.total == 1000 && reading.available == 500 && reading.sequence == 1)
  } catch {
    observation.cancel()
    await session.close()
    _ = await observation.result
    throw error
  }
  try await sendPeer("diagnostic\u{1b}[0m\n", to: sockets.peers[2])
  await session.close()
  wire.close()
  #expect(wire.diagnosticText == "diagnostic?[0m\n" && wire.cleanupErrors.isEmpty)
  for peer in sockets.peers { expectPeerEOF(peer) }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func nativeSocketEOFRejectsLiveRepliesButKeepsTheFinalQuitAcknowledgement(quit: Bool)
  async throws
{
  let sockets = try MemorySockets()
  let wire = try sockets.wire()
  defer { wire.close() }
  try sockets.closeSources()
  let session = try NativeMemorySession(wire: wire, maximumGuestBytes: 1000)
  try await sendPeer("MEMORY_READY 1000 900\n", to: sockets.peers[1])
  try await session.start()
  // Queue the bytes and kernel EOF before reading, rather than race a live reader with shutdown.
  try await sendPeer("MEMORY_OK 1 1000 900\n", to: sockets.peers[1])
  try #require(shutdown(sockets.peers[1].fileDescriptor, SHUT_WR) == 0)
  let pending = Task {
    if quit { try await session.quit() }
    else {
      _ = try await session.observeIfIdle(deadline: .now.advanced(by: .seconds(5)))
    }
  }
  do {
    #expect(try await receivePeerLine(sockets.peers[0]) == (quit ? "QUIT 1\n" : "OBS 1\n"))
    if quit { try await pending.value }
    else { await #expect(throws: NativeControlFailure.disconnected) { try await pending.value } }
  } catch {
    pending.cancel()
    await session.close()
    _ = await pending.result
    throw error
  }
  #expect(wire.cleanupErrors.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func aRefusedNativeCarrierPreservesCallerHandlesAndRetiresConfiguredStreams() async throws {
  let sockets = try MemorySockets(errorType: SOCK_DGRAM)
  // The first two duplicates configure successfully; the third carrier must be refused.
  #expect(throws: NativeControlFailure.ownership) { try sockets.wire() }
  for index in 0..<3 {
    try await sendPeer("owned\n", to: sockets.peers[index])
    var bytes = [UInt8](repeating: 0, count: 16)
    let count = bytes.withUnsafeMutableBytes {
      Darwin.read(sockets.sources[index].fileDescriptor, $0.baseAddress!, $0.count)
    }
    try #require(count == 6)
    #expect(Array(bytes.prefix(count)) == Array("owned\n".utf8))
  }
  try sockets.closeSources()
  // Datagram peers do not report stream EOF; the two stream peers expose leaked setup copies.
  expectPeerEOF(sockets.peers[0])
  expectPeerEOF(sockets.peers[1])
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func aBackpressuredNativeSendHonorsItsDeadlineAndCancellation(cancel: Bool) async throws {
  let sockets = try MemorySockets()
  try sockets.fillInput()
  let wire = try sockets.wire()
  defer { wire.close() }
  try sockets.closeSources()
  let deadline = ContinuousClock.now.advanced(by: cancel ? .seconds(5) : .milliseconds(50))
  let pending = Task.immediate { try await wire.send(Data("OBS 1\n".utf8), until: deadline) }
  if cancel {
    pending.cancel()
    await #expect(throws: CancellationError.self) { try await pending.value }
  } else {
    await #expect(throws: NativeControlFailure.wireTimedOut) { try await pending.value }
  }
  wire.close()
  #expect(wire.cleanupErrors.isEmpty)
}
