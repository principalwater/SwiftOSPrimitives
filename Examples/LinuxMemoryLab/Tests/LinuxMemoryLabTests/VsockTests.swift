import Containerization
import Darwin
import Foundation
import Testing

@testable import NativeLinuxVMM

private func guestPacket(
  operation: UInt16, forwarded: UInt32 = 0, source: UInt32 = 1024,
  destination: UInt32 = 0x2000_0000, flags: UInt32 = 0, payload: Data = Data()
) -> Data {
  // Linux UAPI virtio_vsock_hdr layout, deliberately independent of the host encoder.
  var bytes: [UInt8] = [
    3, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0,
  ]
  for value in [source, destination] {
    bytes += (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
  }
  for value in [UInt32(payload.count)] {
    bytes += (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
  }
  bytes += [
    1, 0, UInt8(truncatingIfNeeded: operation), UInt8(operation >> 8),
  ]
  bytes += (0..<4).map { UInt8(truncatingIfNeeded: flags >> ($0 * 8)) }
  bytes += [0, 0, 1, 0]
  bytes += (0..<4).map { UInt8(truncatingIfNeeded: forwarded >> ($0 * 8)) }
  bytes += payload
  return Data(bytes)
}
private func control() -> NativeControl {
  let unused = URL(filePath: "/not-opened-by-device-tests")
  return NativeControl(
    kernel: unused, initfs: unused, rootfs: unused, console: unused,
    held: false, alias: false)
}

@Test func vsockHeaderMatchesLinuxUAPI() {
  let bytes = VsockDevice.Packet(source: 0x2000_0000, destination: 1024, operation: 1).encoded()
  #expect(
    bytes
      == Data([
        2, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 32, 0, 4, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0,
        0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0,
      ]))
}

@Test func vsockCreditsAndRealSocketPayloadRemainBounded() throws {
  let device = VsockDevice(control: control())
  let pair = try VsockDevice.pair()
  defer {
    _ = Darwin.close(pair.1)
    device.close()
  }
  try device.open(1024, descriptor: pair.0, token: 0x2000_0000)
  try device.receive(guestPacket(operation: 2))
  let bytes = Data([0x51, 0xa2, 0x13, 0xf4])
  let written = bytes.withUnsafeBytes { Darwin.write(pair.1, $0.baseAddress!, $0.count) }
  #expect(written == bytes.count)
  device.transport.status = 12
  try device.poll(
    memory: { _, _ in throw DeviceFailure.request },
    payloadMemory: { _, _ in throw DeviceFailure.request })
  let payload = try #require(device.packets.first(where: { $0.operation == 5 }))
  #expect(payload.payload == bytes)
  #expect(device.connections.values.first?.sent == 4)
  try device.receive(guestPacket(operation: 6, forwarded: 4))
  #expect(device.connections.values.first?.forwarded == 4)
  #expect(throws: (any Error).self) {
    try device.receive(guestPacket(operation: 6, forwarded: UInt32.max))
  }
}

@Test func invalidVsockPeerCannotDeliverToHostSocket() throws {
  let device = VsockDevice(control: control())
  defer { device.close() }
  var invalid = guestPacket(operation: 1)
  invalid[0] = 4
  #expect(throws: (any Error).self) { try device.receive(invalid) }
  #expect(device.connections.isEmpty)
  #expect(device.packets.isEmpty)
  #expect(throws: (any Error).self) {
    try device.receive(guestPacket(operation: 5, payload: Data(count: 65537)))
  }
}

@Test func vsockFragmentsStreamToAdvertisedReceiveCapacity() throws {
  let fixture = RingFixture()
  fixture.store(UInt64(1024), 0)
  fixture.store(UInt32(80), 8)
  fixture.store(UInt16(2), 12)
  fixture.store(UInt64(2048), 16)
  fixture.store(UInt32(80), 24)
  fixture.store(UInt16(2), 28)
  fixture.store(UInt16(2), 258)
  fixture.store(UInt16(0), 260)
  fixture.store(UInt16(1), 262)
  let device = VsockDevice(control: control())
  device.transport.status = 12
  device.transport.queues[0] = fixture.queue
  let payload = Data((0..<70).map(UInt8.init))
  try device.enqueue(.init(source: 123, destination: 456, operation: 5, payload: payload))
  try device.poll(memory: fixture.memory, payloadMemory: fixture.memory)
  #expect(device.packets.isEmpty)
  #expect(fixture.bytes.loadUnaligned(fromByteOffset: 514, as: UInt16.self) == 2)
  #expect(fixture.bytes.loadUnaligned(fromByteOffset: 1048, as: UInt32.self) == 36)
  #expect(fixture.bytes.loadUnaligned(fromByteOffset: 2072, as: UInt32.self) == 34)
  #expect(Data(bytes: fixture.bytes + 1068, count: 36) == payload.prefix(36))
  #expect(Data(bytes: fixture.bytes + 2092, count: 34) == payload.suffix(34))
}

@Test func vsockDemultiplexesTwoPeersOfOneListener() async throws {
  let state = control()
  let listener = VsockListener(port: 64) { _ in }
  state.state.withLock { $0.listeners[64] = listener }
  let device = VsockDevice(control: state)
  try device.receive(guestPacket(operation: 1, source: 5000, destination: 64))
  try device.receive(guestPacket(operation: 1, source: 5001, destination: 64))
  #expect(device.packets.filter { $0.operation == 2 }.count == 2)
  try device.receive(guestPacket(operation: 5, source: 5000, destination: 64, payload: Data([11])))
  try device.receive(guestPacket(operation: 5, source: 5001, destination: 64, payload: Data([22])))
  device.transport.status = 12
  try device.poll(
    memory: { _, _ in throw DeviceFailure.request },
    payloadMemory: { _, _ in throw DeviceFailure.request })
  device.close()
  try listener.finish()
  var delivered: [UInt8] = []
  for await handle in listener {
    defer { try? handle.close() }
    _ = fcntl(handle.fileDescriptor, F_SETFL, O_NONBLOCK)
    var byte: UInt8 = 0
    let count = Darwin.read(handle.fileDescriptor, &byte, 1)
    #expect(count == 1)
    if count == 1 { delivered.append(byte) }
  }
  #expect(delivered == [11, 22])
}

@Test func vsockResetIgnoresObsoleteCredit() throws {
  let device = VsockDevice(control: control())
  let pair = try VsockDevice.pair()
  defer {
    _ = Darwin.close(pair.1)
    device.close()
  }
  try device.open(1024, descriptor: pair.0, token: 0x2000_0000)
  try device.receive(guestPacket(operation: 2))
  try device.receive(guestPacket(operation: 3, forwarded: 70000))
  #expect(device.connections.isEmpty)
}

@Test func vsockPeerShutdownFlushesTailUnderBackpressure() throws {
  let device = VsockDevice(control: control())
  let pair = try VsockDevice.pair()
  defer {
    _ = Darwin.close(pair.1)
    device.close()
  }
  var capacity: Int32 = 1024
  guard setsockopt(pair.0, SOL_SOCKET, SO_SNDBUF, &capacity, 4) == 0,
    fcntl(pair.1, F_SETFL, O_NONBLOCK) == 0
  else { throw DeviceFailure.native(errno) }
  var length: socklen_t = 4
  guard getsockopt(pair.0, SOL_SOCKET, SO_SNDBUF, &capacity, &length) == 0 else {
    throw DeviceFailure.native(errno)
  }
  try #require(capacity < 32768)
  try device.open(1024, descriptor: pair.0, token: 0x2000_0000)
  try device.receive(guestPacket(operation: 2))
  let payload = Data((0..<65536).map { UInt8(truncatingIfNeeded: $0) })
  try device.receive(guestPacket(operation: 5, payload: payload))
  device.transport.status = 12
  try device.poll(
    memory: { _, _ in throw DeviceFailure.request },
    payloadMemory: { _, _ in throw DeviceFailure.request })
  try device.receive(guestPacket(operation: 4, flags: 3))
  var received = Data()
  for _ in 0..<128 {
    var bytes = [UInt8](repeating: 0, count: 8192)
    let count = Darwin.read(pair.1, &bytes, bytes.count)
    if count > 0 {
      received.append(contentsOf: bytes.prefix(count))
    } else if count == 0 {
      break
    } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
      throw DeviceFailure.native(errno)
    }
    try device.poll(
      memory: { _, _ in throw DeviceFailure.request },
      payloadMemory: { _, _ in throw DeviceFailure.request })
  }
  #expect(received == payload)
  #expect(device.connections.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func repeatedVsockReadsOwnTheirPayloadAndCannotLeakTheScratchTail() throws {
  let device = VsockDevice(control: control())
  let pair = try VsockDevice.pair()
  defer {
    _ = Darwin.close(pair.1)
    device.close()
  }
  try #require(fcntl(pair.1, F_SETFL, O_NONBLOCK) == 0)
  try device.open(1024, descriptor: pair.0, token: 0x2000_0000)
  try device.receive(guestPacket(operation: 2))
  device.transport.status = 12
  let first = Data((0..<16384).map { UInt8(truncatingIfNeeded: $0 &* 17) })
  let second = Data([0xa5, 0x19, 0xff])
  var total = 0
  var original: [Data] = []
  func poll() throws {
    try device.poll(
      memory: { _, _ in throw DeviceFailure.request },
      payloadMemory: { _, _ in throw DeviceFailure.request })
  }
  for data in [first, second] {
    var sent = 0
    var attempts = 0
    while sent < data.count {
      attempts += 1
      try #require(attempts <= 16)
      let written = data.withUnsafeBytes {
        Darwin.write(pair.1, $0.baseAddress! + sent, $0.count - sent)
      }
      if written > 0 { sent += written }
      else { try #require(written < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno)) }
      try poll()
    }
    total += data.count
    for _ in 0..<16 where device.connections.values.first?.sent != UInt32(total) {
      try poll()
    }
    try #require(device.connections.values.first?.sent == UInt32(total))
    if original.isEmpty { original = device.packets.filter { $0.operation == 5 }.map(\.payload) }
  }
  let packets = device.packets.filter { $0.operation == 5 }.map(\.payload)
  #expect(Array(packets.prefix(original.count)) == original)
  #expect(packets.reduce(into: Data()) { $0.append($1) } == first + second)
  for _ in 0..<10 { try poll() }
  #expect(device.packets.filter { $0.operation == 5 }.map(\.payload) == packets)
}
