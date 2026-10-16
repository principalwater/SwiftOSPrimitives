import Foundation
import Testing

@testable import container_native_lab

@Test func peerIgnoresWellFormedICMPWithoutForwarding() throws {
  // Golden IPv4/ICMP echo request; this finite peer serves only UDP echo.
  let frame = Data([
    2, 0, 0, 0, 0, 1, 2, 0, 0, 0, 0, 2, 8, 0, 69, 0, 0, 28, 0, 1, 0, 0, 64, 1, 246, 220, 192, 0, 2,
    2, 192, 0, 2, 1, 8, 0, 247, 255, 0, 0, 0, 0,
  ])
  #expect(try EthernetPeer.reply(frame) == nil)
}
