import Testing

@testable import NativeLinuxVMM

@Test func reportingSelectsOnlyWholeDynamicExtentsWithinTheCurrentChain() throws {
  let base = MemoryDevice.base
  let buffers = [
    GuestBuffer(address: base + 2 * (2 << 20), size: 2 << 20, writable: true),
    GuestBuffer(address: 0x4000_0000, size: 2 << 20, writable: true),
    GuestBuffer(address: base + 4096, size: (2 << 20) - 4096, writable: true),
  ]
  let indices = try FreePageReportingDevice.indices(
    buffers, boot: 0x4000_0000..<0x8000_0000, dynamicBytes: 128 << 20)
  #expect(indices == [2])
  let adjacentPartial = [
    GuestBuffer(address: base, size: 4096, writable: true),
    GuestBuffer(address: base + 4096, size: (2 << 20) - 4096, writable: true),
  ]
  #expect(
    try FreePageReportingDevice.indices(
      adjacentPartial, boot: 0x4000_0000..<0x8000_0000, dynamicBytes: 128 << 20).isEmpty)
}

@Test(arguments: 0..<8)
func malformedReportsAreRejectedBeforeRecycling(_ kind: Int) {
  let base = MemoryDevice.base
  var buffers = [GuestBuffer(address: base, size: 2 << 20, writable: true)]
  switch kind {
  case 0: buffers = []
  case 1: buffers = [.init(address: base, size: 2 << 20, writable: false)]
  case 2: buffers = [.init(address: base + 1, size: 2 << 20, writable: true)]
  case 3: buffers = [.init(address: base, size: 4097, writable: true)]
  case 4: buffers = [.init(address: UInt64.max - 4095, size: 4096, writable: true)]
  case 5: buffers = [.init(address: base + (128 << 20), size: 4096, writable: true)]
  case 6: buffers += buffers
  default: buffers = [.init(address: 0x0a00_6000, size: 4096, writable: true)]
  }
  #expect(throws: DeviceFailure.self) {
    _ = try FreePageReportingDevice.indices(
      buffers, boot: 0x4000_0000..<0x8000_0000, dynamicBytes: 128 << 20)
  }
}

@Test func reportingWireAcknowledgesBootPagesWithoutReclaimAndResetCannotReplayThem() throws {
  let fixture = RingFixture()
  fixture.store(UInt64(4096), 0)
  fixture.store(UInt32(4096), 8)
  fixture.store(UInt16(2), 12)
  let device = FreePageReportingDevice()
  let memory = MemoryDevice(held: false)
  func write(_ offset: UInt64, _ value: UInt32) throws {
    _ = try device.access(
      offset, width: 4, write: value, boot: 0..<16384, memory: memory,
      metadata: fixture.memory, quiescence: (true, 1, 2))
  }
  try write(0x70, 3)
  try write(0x20, 1 << 5)
  try write(0x24, 1)
  try write(0x20, 1)
  try write(0x70, 11)
  try write(0x30, 2)
  for (offset, value): (UInt64, UInt32) in [(0x38, 8), (0x80, 0), (0x90, 256), (0xa0, 512)] {
    try write(offset, value)
  }
  try write(0x44, 1)
  try write(0x70, 15)
  #expect(throws: DeviceFailure.self) { try write(0x104, 1) }
  #expect(throws: DeviceFailure.self) { try write(0x50, 0) }
  #expect(throws: DeviceFailure.self) { try write(0x50, 4) }
  #expect(device.reports == 0)
  try write(0x50, 2)
  #expect(device.reports == 1 && device.reportedBytes == 4096)
  #expect(memory.recycledBackingBytes == 0 && memory.recyclingObservations.isEmpty)
  #expect(fixture.bytes.loadUnaligned(fromByteOffset: 514, as: UInt16.self) == 1)
  try write(0x50, 2)
  #expect(device.reports == 1)
  for published: UInt16 in 2...71 {
    fixture.store(published, 258)
    try write(0x50, 2)
  }
  #expect(device.reports == 71 && device.reportedBytes == 71 * 4096)
  #expect(device.observations.count == 64)
  #expect(device.observations.first?["sequence"] == 8)
  #expect(device.observations.last?["sequence"] == 71)
  #expect(
    device.observations.allSatisfy {
      guard let received = $0["receivedAtNanoseconds"], let completed = $0["completedAtNanoseconds"]
      else { return false }
      return $0["residentBytesRecycled"] == 0 && received <= completed
    })
  try write(0x70, 0)
  #expect(throws: DeviceFailure.self) { try write(0x50, 2) }
  #expect(device.reports == 71)
}

@Test(arguments: [false, true])
func reportingLengthAllowanceDoesNotWeakenOtherQueues(_ reporting: Bool) throws {
  let fixture = RingFixture()
  fixture.store(UInt32(2 << 20), 8)
  fixture.store(UInt16(2), 12)
  if reporting {
    let changed = try fixture.queue.drain(
      maximumBufferBytes: 64 << 20, memory: fixture.memory
    ) { buffers in
      #expect(buffers.count == 1 && buffers[0].size == 2 << 20)
      return 0
    }
    #expect(changed)
  } else {
    #expect(throws: DeviceFailure.self) {
      _ = try fixture.queue.drain(memory: fixture.memory) { _ in
        Issue.record("Oversized ordinary descriptor was processed", severity: .error)
        return 0
      }
    }
  }
}
