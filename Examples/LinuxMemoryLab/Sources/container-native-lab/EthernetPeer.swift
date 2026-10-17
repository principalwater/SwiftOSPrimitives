import Foundation
import NativeLinuxVMM
import Synchronization

// A finite RFC5737 peer, not a host IP stack or a bridge to any external network.
final class EthernetPeer: Sendable {
  let link: IsolatedNetwork
  private let state = Mutex((stop: false, echoed: 0, backpressure: UInt64(0)))
  init(link: IsolatedNetwork) { self.link = link }
  var echoed: Int { state.withLock { $0.echoed } }
  var backpressure: UInt64 { state.withLock { $0.backpressure } }
  func stop() {
    state.withLock { $0.stop = true }
    link.stopReceiving()
  }
  func run() async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { try await self.respond() }
      group.addTask {
        try await Task.sleep(for: .seconds(150))
        throw NativeControlFailure.wireTimedOut
      }
      defer { group.cancelAll() }
      _ = try await group.next()
    }
  }
  private func respond() async throws {
    var pending: (frame: Data, counted: Bool)?
    let deadline = ContinuousClock.now.advanced(by: .seconds(150))
    while !state.withLock({ $0.stop }) {
      try Task.checkCancellation()
      guard ContinuousClock.now < deadline, echoed < 100000 else {
        throw NativeControlFailure.wireTimedOut
      }
      if let packet = pending {
        if try link.send(packet.frame) {
          pending = nil
          if packet.counted { state.withLock { $0.echoed += 1 } }
        } else {
          state.withLock { if $0.backpressure < UInt64.max { $0.backpressure += 1 } }
          try await Task.sleep(for: .milliseconds(1))
        }
      } else {
        let packet: Data
        do { packet = try await link.receivePacket() } catch is CancellationError {
          guard state.withLock({ $0.stop }) else { throw CancellationError() }
          return
        }
        if let frame = try Self.reply(packet, index: link.index) {
          pending = (frame, packet[12] == 8 && packet[13] == 0)
        }
      }
    }
  }
  static func checksum(_ bytes: Data) -> UInt16 {
    var sum: UInt32 = 0
    var index = 0
    while index + 1 < bytes.count {
      sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
      index += 2
    }
    if index < bytes.count { sum += UInt32(bytes[index]) << 8 }
    while sum > 65535 { sum = (sum & 65535) + (sum >> 16) }
    return ~UInt16(sum)
  }
  static func reply(_ frame: Data, index: Int = 0) throws -> Data? {
    guard (14...1514).contains(frame.count) else { throw NativeControlFailure.framing }
    guard (0...1).contains(index) else { throw NativeControlFailure.framing }
    let guest: [UInt8] = [2, 0, 0, 0, UInt8(index), 2]
    let peer: [UInt8] = [2, 0, 0, 0, UInt8(index), 1]
    let prefix: [UInt8] = index == 0 ? [192, 0, 2] : [198, 51, 100]
    let guestIP = prefix + [2]
    let peerIP = prefix + [1]
    guard Array(frame[6..<12]) == guest else { throw NativeControlFailure.framing }
    func word(_ offset: Int) -> Int { Int(frame[offset]) << 8 | Int(frame[offset + 1]) }
    if word(12) == 0x806 {
      guard frame.count >= 42, word(14) == 1, word(16) == 0x800,
        frame[18] == 6, frame[19] == 4
      else { throw NativeControlFailure.framing }
      guard word(20) == 1, Array(frame[28..<32]) == guestIP,
        Array(frame[38..<42]) == peerIP
      else { return nil }
      var response = Data(guest + peer + [8, 6, 0, 1, 8, 0, 6, 4, 0, 2])
      response.append(contentsOf: peer + peerIP + guest + guestIP)
      return response
    }
    guard word(12) == 0x800 else { return nil }
    guard frame.count >= 34, Array(frame[0..<6]) == peer, frame[14] == 0x45,
      word(16) >= 20, word(16) <= frame.count - 14,
      word(20) & 0x3fff == 0,
      Array(frame[26..<30]) == guestIP, Array(frame[30..<34]) == peerIP,
      checksum(Data(frame[14..<34])) == 0
    else { throw NativeControlFailure.framing }
    guard frame[23] == 17 else { return nil }
    guard frame.count >= 42, word(16) >= 28, word(36) == 7070, word(38) == word(16) - 20
    else { throw NativeControlFailure.framing }
    let end = 14 + word(16)
    let datagram = Data(frame[34..<end])
    if word(40) != 0 {
      var pseudo = Data(frame[26..<34])
      pseudo.append(contentsOf: [0, 17, frame[38], frame[39]])
      pseudo.append(datagram)
      guard checksum(pseudo) == 0 else { throw NativeControlFailure.framing }
    }
    var response = Data(frame.prefix(end))
    response.replaceSubrange(0..<6, with: guest)
    response.replaceSubrange(6..<12, with: peer)
    response.replaceSubrange(26..<30, with: peerIP)
    response.replaceSubrange(30..<34, with: guestIP)
    response.replaceSubrange(34..<36, with: frame[36..<38])
    response.replaceSubrange(36..<38, with: frame[34..<36])
    response[24] = 0
    response[25] = 0
    let ipChecksum = checksum(Data(response[14..<34]))
    response[24] = UInt8(ipChecksum >> 8)
    response[25] = UInt8(truncatingIfNeeded: ipChecksum)
    response[40] = 0
    response[41] = 0
    var pseudo = Data(response[26..<34])
    pseudo.append(contentsOf: [0, 17, response[38], response[39]])
    pseudo.append(response[34..<end])
    let udpChecksum = checksum(pseudo)
    let encoded = udpChecksum == 0 ? UInt16.max : udpChecksum
    response[40] = UInt8(encoded >> 8)
    response[41] = UInt8(truncatingIfNeeded: encoded)
    return response
  }
}
