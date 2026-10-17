import Foundation
import Testing

@testable import NativeLinuxVMM

@Test func balloonOwnershipCoalescesPacketsAndResetCannotReplayOldPFNs() throws {
  var ledger = try BalloonPFNs(boot: 0x4000_0000..<0x6000_0000, dynamicBytes: 128 << 20)
  let first = (UInt32(0x10_0000)..<0x10_0100).map { $0 }
  let second = (UInt32(0x10_0100)..<0x10_0200).map { $0 }
  #expect(try ledger.transfer(first, inflate: true).isEmpty)
  #expect(ledger.count == 256)
  #expect(try ledger.transfer(second, inflate: true) == [0])
  #expect(ledger.count == 512)
  #expect(ledger.dynamicCount == 512)
  for invalid in [[first[0]], [second[0], second[0]], [0], [UInt32(0x10_8000)]] {
    #expect(throws: DeviceFailure.self) { _ = try ledger.transfer(invalid, inflate: true) }
    #expect(ledger.count == 512)
  }
  #expect(try ledger.transfer([first[0]], inflate: false).isEmpty)
  #expect(ledger.count == 511)
  #expect(try !ledger.overlapsOwned(address: 0x1_0000_0000, count: 4096))
  #expect(try ledger.overlapsOwned(address: 0x1_0000_0fff, count: 2))
  #expect(try ledger.transfer([first[0]], inflate: true) == [0])
  #expect(try ledger.transfer(first, inflate: false).isEmpty)
  #expect(try ledger.transfer(second, inflate: false).isEmpty)
  #expect(ledger.count == 0)
  #expect(try ledger.transfer([UInt32(0x4_0000)], inflate: true).isEmpty)
  #expect(ledger.count == 1 && ledger.dynamicCount == 0)
  try ledger.reset()
  #expect(ledger.count == 0 && ledger.dynamicCount == 0 && ledger.epoch == 2)
  #expect(throws: DeviceFailure.self) {
    _ = try ledger.transfer([UInt32(0x4_0000)], inflate: false)
  }
  #expect(ledger.count == 0)
}

@Test(arguments: [UInt32(0), 1, 4, 5])
func classicBalloonRequiresBothRescueFeatures(_ lowFeatures: UInt32) throws {
  let fixture = RingFixture()
  let device = try ClassicBalloonDevice(boot: 0..<(2 << 20), dynamicBytes: 128 << 20)
  let transport = device.transport
  for (offset, value): (UInt64, UInt32) in [
    (0x70, 3), (0x20, lowFeatures), (0x24, 1), (0x20, 1), (0x70, 11),
  ] { _ = try transport.write(offset, value, memory: fixture.memory) }
  #expect((transport.read(0x70) & 8 != 0) == (lowFeatures == 5))
}

@Test func balloonWireRefusalAcknowledgesAndDeflateStillDrainsBeforeReset() throws {
  let fixture = RingFixture(byteCount: 32768)
  let memory = MemoryDevice(held: false)
  let device = try ClassicBalloonDevice(boot: 0..<(2 << 20), dynamicBytes: 128 << 20)
  func write(_ offset: UInt64, _ value: UInt32) throws {
    _ = try device.access(
      offset, width: 4, write: value, memory: memory,
      metadata: fixture.memory, payload: fixture.memory, quiescence: (true, 1, 2))
  }
  try write(0x70, 3)
  try write(0x20, 5)
  try write(0x24, 1)
  try write(0x20, 1)
  try write(0x70, 11)
  for queue: UInt32 in 0...1 {
    let base = queue * 4096
    fixture.store(UInt64(8192 + base), Int(base))
    fixture.store(UInt32(1024), Int(base + 8))
    fixture.store(UInt16(0), Int(base + 12))
    fixture.store(UInt16(1), Int(base + 258))
    for index: UInt32 in 0..<256 {
      fixture.store(256 + index, Int(8192 + base + index * 4))
    }
    try write(0x30, queue)
    for (offset, value): (UInt64, UInt32) in [
      (0x38, 8), (0x80, base), (0x90, base + 256), (0xa0, base + 512),
    ] { try write(offset, value) }
    try write(0x44, 1)
  }
  try write(0x70, 15)
  try write(0x50, 0)
  #expect(device.ledger.count == 256 && device.accepted == 1)
  #expect(memory.recycledBackingBytes == 0)
  fixture.store(UInt16(2), 258) // Duplicate inflate must ACK, quarantine and retain prior ownership.
  try write(0x50, 0)
  #expect(fixture.bytes.loadUnaligned(fromByteOffset: 514, as: UInt16.self) == 2)
  #expect(device.target == 0 && device.quarantined && device.refused == 1)
  #expect(device.ledger.count == 256)
  fixture.store(UInt32(0), 12288 + 255 * 4) // Mix 255 owned PFNs with an unowned boot PFN.
  try write(0x50, 1)
  #expect(fixture.bytes.loadUnaligned(fromByteOffset: 4610, as: UInt16.self) == 1)
  try #require(device.ledger.count == 1)
  #expect(try !device.ledger.overlapsOwned(address: 256 * 4096, count: 4096))
  #expect(try device.ledger.overlapsOwned(address: 511 * 4096, count: 4096))
  fixture.store(UInt32(511), 12288 + 255 * 4)
  fixture.store(UInt16(2), 4354)
  try write(0x50, 1)
  #expect(fixture.bytes.loadUnaligned(fromByteOffset: 4610, as: UInt16.self) == 2)
  #expect(device.ledger.count == 0 && device.accepted == 1 && device.refused == 3)
  fixture.store(UInt32(1023), 4104) // An undecodable deflate cannot be ACKed as a release.
  fixture.store(UInt16(3), 4354)
  #expect(throws: DeviceFailure.self) { try write(0x50, 1) }
  #expect(fixture.bytes.loadUnaligned(fromByteOffset: 4610, as: UInt16.self) == 2)
  #expect(memory.recycledBackingBytes == 0)
  let epoch = device.ledger.epoch
  try write(0x70, 0)
  #expect(device.ledger.epoch == epoch + 1 && device.target == 0 && device.actual == 0)
  #expect(throws: DeviceFailure.self) { try write(0x50, 0) }
}

@Test func balloonAdmissionRefusesMissingBackingAndStillAllowsZeroRescue() throws {
  let memory = MemoryDevice(held: false)
  let device = try ClassicBalloonDevice(boot: 0..<(2 << 20), dynamicBytes: 128 << 20)
  let fixture = RingFixture()
  for (offset, value): (UInt64, UInt32) in [
    (0x70, 3), (0x20, 5), (0x24, 1), (0x20, 1), (0x70, 15),
  ] { _ = try device.transport.write(offset, value, memory: fixture.memory) }
  #expect(throws: DeviceFailure.self) {
    try device.request(bytes: 1 << 20, memory: memory, now: .now)
  }
  #expect(device.target == 0 && device.ledger.count == 0 && device.leaseExpirations == 0)
  try device.poll(now: .now, quarantine: true)
  try device.request(bytes: 0, memory: memory, now: .now)
  #expect(device.target == 0 && device.quarantined)
}
