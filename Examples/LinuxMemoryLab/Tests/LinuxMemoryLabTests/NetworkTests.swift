import Darwin
import Foundation
import Testing

@testable import NativeLinuxVMM

@Test func ethernetBytesCrossBothVirtqueues() throws {
  let link = try IsolatedNetwork()
  let device = try NetworkDevice(network: link)
  defer {
    try? device.close()
    try? link.close()
  }
  let fixture = RingFixture()
  let frame = Data([2, 0, 0, 0, 0, 1, 2, 0, 0, 0, 0, 2, 8, 6] + [UInt8](repeating: 7, count: 28))
  var tx = Data(count: 12)
  tx.append(frame)
  tx.withUnsafeBytes {
    fixture.bytes.advanced(by: 1024).copyMemory(from: $0.baseAddress!, byteCount: $0.count)
  }
  fixture.store(UInt32(tx.count), 8)
  fixture.store(UInt16(0), 12)
  device.transport.status = 15
  device.transport.queues[1] = fixture.queue
  try device.poll(memory: fixture.memory, payloadMemory: fixture.memory)
  #expect(try link.receive() == frame)
  #expect(device.txPackets == 1)
  #expect(fixture.bytes.loadUnaligned(fromByteOffset: 514, as: UInt16.self) == 1)
  fixture.store(UInt32(2048), 8)
  fixture.store(UInt16(2), 12)
  device.transport.queues[0] = fixture.queue
  #expect(try link.send(frame))
  try device.poll(memory: fixture.memory, payloadMemory: fixture.memory)
  #expect(device.rxPackets == 1)
  #expect(fixture.bytes.loadUnaligned(fromByteOffset: 520, as: UInt32.self) == tx.count)
  var expectedRX = Data(count: 12)
  expectedRX[10] = 1
  expectedRX.append(frame)
  #expect(Data(bytes: fixture.bytes.advanced(by: 1024), count: tx.count) == expectedRX)
}

@Test func ethernetBackpressureAndOwnershipRemainBounded() throws {
  let link = try IsolatedNetwork(index: 1)
  let fd = try link.claim()
  defer {
    _ = Darwin.close(fd)
    try? link.close()
  }
  #expect(throws: NativeFailure.self) { _ = try link.claim() }
  #expect(link.ipv4Gateway == nil)
  let frame = Data(repeating: 42, count: 1514)
  var sent = 0
  while sent < 1024, try link.send(frame) { sent += 1 }
  #expect(sent > 0 && sent < 1024)
  #expect(try IsolatedNetwork.receive(descriptor: fd) == frame)
  #expect(throws: DeviceFailure.self) { _ = try link.send(Data(count: 1515)) }
  try link.close()
  #expect(throws: NativeFailure.self) { _ = try link.send(frame) }
}

@Test(arguments: [false, true])
func ethernetRefusesOffloadAndFailedDevice(_ failed: Bool) throws {
  let link = try IsolatedNetwork()
  let device = try NetworkDevice(network: link)
  defer {
    try? device.close()
    try? link.close()
  }
  let fixture = RingFixture()
  fixture.store(UInt32(64), 8)
  fixture.store(UInt16(0), 12)
  fixture.store(UInt8(1), 1024)
  device.transport.status = failed ? 143 : 15
  device.transport.queues[1] = fixture.queue
  if failed {
    try device.poll(memory: fixture.memory, payloadMemory: fixture.memory)
  } else {
    #expect(throws: DeviceFailure.self) {
      try device.poll(memory: fixture.memory, payloadMemory: fixture.memory)
    }
  }
  #expect(fixture.bytes.loadUnaligned(fromByteOffset: 514, as: UInt16.self) == 0)
  #expect(try link.receive() == nil)
}
