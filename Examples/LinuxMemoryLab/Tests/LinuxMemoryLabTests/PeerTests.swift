import Darwin
import Foundation
import Testing

@testable import NativeLinuxVMM
@testable import container_native_lab

@Test func peerIgnoresWellFormedICMPWithoutForwarding() throws {
  // Golden IPv4/ICMP echo request; this finite peer serves only UDP echo.
  let frame = Data([
    2, 0, 0, 0, 0, 1, 2, 0, 0, 0, 0, 2, 8, 0, 69, 0, 0, 28, 0, 1, 0, 0, 64, 1, 246, 220, 192, 0, 2,
    2, 192, 0, 2, 1, 8, 0, 247, 255, 0, 0, 0, 0,
  ])
  #expect(try EthernetPeer.reply(frame) == nil)
}

@Test(.timeLimit(.minutes(1)))
func peerCountsOnlyDeliveredFramesUnderRealBackpressure() async throws {
  let link = try IsolatedNetwork()
  let device = try link.claim()
  defer {
    _ = Darwin.close(device)
    try? link.close()
  }
  // Fill with minimum frames: rejecting a large filler can still leave room for the small reply.
  let filler = Data(repeating: 3, count: 14)
  var queued = 0
  while queued < 1024, try link.send(filler) { queued += 1 }
  try #require(queued > 0 && queued < 1024)
  let peer = EthernetPeer(link: link)
  let run = Task { try await peer.run() }
  defer {
    peer.stop()
    run.cancel()
  }
  // Golden IPv4/UDP request, zero UDP checksum is valid for this IPv4 datagram.
  let request = Data([
    2, 0, 0, 0, 0, 1, 2, 0, 0, 0, 0, 2, 8, 0, 69, 0, 0, 28, 0, 1, 0, 0,
    64, 17, 246, 204, 192, 0, 2, 2, 192, 0, 2, 1, 27, 159, 27, 158, 0, 8, 0, 0,
  ])
  try #require(try IsolatedNetwork.transmit(request, descriptor: device))
  let deadline = ContinuousClock.now.advanced(by: .seconds(3))
  while peer.backpressure == 0 {
    guard ContinuousClock.now < deadline else { throw NativeFailure.deadline }
    try await Task.sleep(for: .milliseconds(1))
  }
  #expect(peer.echoed == 0)
  for _ in 0..<queued {
    #expect(try IsolatedNetwork.receive(descriptor: device) == filler)
  }
  var delivered: Data?
  while delivered == nil {
    guard ContinuousClock.now < deadline else { throw NativeFailure.deadline }
    delivered = try IsolatedNetwork.receive(descriptor: device)
    if delivered == nil { try await Task.sleep(for: .milliseconds(1)) }
  }
  let response = try #require(delivered)
  #expect(response.count == request.count)
  #expect(Array(response[0..<6]) == [2, 0, 0, 0, 0, 2])
  #expect(Array(response[34..<38]) == [27, 158, 27, 159])
  while peer.echoed == 0 {
    guard ContinuousClock.now < deadline else { throw NativeFailure.deadline }
    try await Task.sleep(for: .milliseconds(1))
  }
  #expect(peer.echoed == 1)
  peer.stop()
  try await run.value
}
