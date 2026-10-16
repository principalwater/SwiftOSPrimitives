import Darwin
import Foundation
import Testing

@testable import NativeLinuxVMM

// Golden little-endian virtio bytes; no hypervisor or emulated result generator.
final class RingFixture {
  let bytes: UnsafeMutableRawPointer
  let byteCount: Int
  var queue = SplitQueue(size: 8, descriptors: 0, available: 256, used: 512, ready: true)
  init(byteCount: Int = 16384) {
    self.byteCount = byteCount
    bytes = .allocate(byteCount: byteCount, alignment: 16)
    bytes.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
    store(UInt64(1024), 0)
    store(UInt32(24), 8)
    store(UInt16(1), 12)
    store(UInt16(1), 14)
    store(UInt64(2048), 16)
    store(UInt32(10), 24)
    store(UInt16(2), 28)
    store(UInt16(1), 258)
  }
  deinit { bytes.deallocate() }
  func store<T: FixedWidthInteger>(_ value: T, _ offset: Int) {
    bytes.storeBytes(of: value.littleEndian, toByteOffset: offset, as: T.self)
  }
  func memory(_ address: UInt64, _ count: Int) throws -> UnsafeMutableRawPointer {
    guard address <= UInt64(byteCount), count >= 0, UInt64(count) <= UInt64(byteCount) - address
    else {
      throw DeviceFailure.geometry
    }
    return bytes.advanced(by: Int(address))
  }
}

@Test func deliversChainAndPublishesCompletion() throws {
  let fixture = RingFixture()
  var calls = 0
  let changed = try fixture.queue.drain(memory: fixture.memory) { buffers in
    calls += 1
    #expect(buffers.count == 2)
    #expect(buffers[0].address == 1024 && buffers[0].size == 24 && !buffers[0].writable)
    #expect(buffers[1].address == 2048 && buffers[1].size == 10 && buffers[1].writable)
    return 10
  }
  #expect(changed)
  #expect(calls == 1)
  #expect(fixture.bytes.loadUnaligned(fromByteOffset: 514, as: UInt16.self) == 1)
  #expect(fixture.bytes.loadUnaligned(fromByteOffset: 516, as: UInt32.self) == 0)
  #expect(fixture.bytes.loadUnaligned(fromByteOffset: 520, as: UInt32.self) == 10)
  #expect(
    try !fixture.queue.drain(memory: fixture.memory) { _ in
      Issue.record("Completed request replayed", severity: .error)
      return 0
    })
}

@Test(arguments: 0..<6)
func refusesMalformedChainsBeforeProcessing(_ kind: Int) throws {
  let fixture = RingFixture()
  switch kind {
  case 0: fixture.store(UInt16(8), 260)  // Head outside descriptor table.
  case 1:
    fixture.store(UInt16(1), 28)
    fixture.store(UInt16(0), 30)  // Cycle.
  case 2: fixture.store(UInt16(4), 12)  // Unnegotiated indirect descriptor.
  case 3: fixture.store(UInt64.max, 0)  // Address overflow.
  case 4: fixture.store(UInt64(512), 0)  // Aliases used ring.
  default: fixture.store(UInt16(9), 258)  // Over-published available entries.
  }
  var calls = 0
  #expect(throws: DeviceFailure.self) {
    _ = try fixture.queue.drain(memory: fixture.memory) { _ in
      calls += 1
      return 0
    }
  }
  #expect(calls == 0)
  #expect(fixture.bytes.loadUnaligned(fromByteOffset: 514, as: UInt16.self) == 0)
}

@Test(arguments: [false, true])
func requiresVersionAndOfferedFeatures(_ missingMemoryFeature: Bool) throws {
  let fixture = RingFixture()
  let device = MemoryDevice(held: false).transport
  _ = try device.write(0x70, 3, memory: fixture.memory)
  if missingMemoryFeature {
    _ = try device.write(0x24, 1, memory: fixture.memory)
    _ = try device.write(0x20, 1, memory: fixture.memory)
  } else {
    _ = try device.write(0x20, 2, memory: fixture.memory)
  }
  _ = try device.write(0x70, 11, memory: fixture.memory)
  #expect(device.read(0x70) & 8 == 0)
  #expect(throws: DeviceFailure.self) { _ = try device.write(0x50, 0, memory: fixture.memory) }
}

@Test func memoryStateUsesWireRangesAndRefusesInvalidPFNs() throws {
  let device = MemoryDevice(held: false)
  var request = Data(count: 24)
  request[0] = 3
  request[12] = 1  // GPA0x100000000, independent little-endian literal.
  request[16] = 1
  #expect(
    try device.request(request, quiescence: (true, 0, 1)) == Data([0, 0, 0, 0, 0, 0, 0, 0, 1, 0]))
  request[8] = 1  // Misaligned GPA.
  #expect(
    try device.request(request, quiescence: (true, 0, 1)) == Data([3, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
  request[8] = 0
  request[16] = 65  // Region overflow.
  #expect(
    try device.request(request, quiescence: (true, 0, 1)) == Data([3, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
  #expect(device.plugged == 0 && device.observations.isEmpty)
}

@Test func quarantinedMemoryWireRefusesMutationsButRetainsValidationAndStateReads() throws {
  let device = MemoryDevice(held: false)
  #expect(throws: DeviceFailure.self) {
    try device.quarantine(quiescence: (false, 7, 2))
  }
  #expect(!device.quarantined)
  try device.quarantine(quiescence: (true, 7, 2))
  #expect(device.quarantined && device.requested == 0)
  for kind: UInt8 in [0, 1, 2] {
    var request = Data(count: 24)
    request[0] = kind
    request[12] = 1
    request[16] = 1
    #expect(
      try device.request(request, quiescence: (true, 8, 2))
        == Data([2, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
  }
  var state = Data(count: 24)
  state[0] = 3
  state[12] = 1
  state[16] = 1
  #expect(
    try device.request(state, quiescence: (true, 8, 2))
      == Data([0, 0, 0, 0, 0, 0, 0, 0, 1, 0]))
  state[0] = 1
  state[8] = 1
  #expect(
    try device.request(state, quiescence: (true, 8, 2))
      == Data([3, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
  try device.quarantine(quiescence: (true, 9, 2))
  #expect(device.quarantineRecord["epoch"] == 7)
  #expect(device.plugged == 0 && device.observations.isEmpty)
}

@Test func unsupportedDiskCommandReturnsStatusWithoutIO() throws {
  let temporaryPath = try #require(ProcessInfo.processInfo.environment["TMPDIR"])
  let root = URL(filePath: temporaryPath, directoryHint: .isDirectory)
    .appending(path: UUID().uuidString)
  let artifacts = root.appending(path: "artifacts")
  let marker = root.appending(path: "OWNER.json")
  let disk = artifacts.appending(path: "clickhouse-run-unit.ext4")
  try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
  defer {
    _ = unlink(disk.path)
    _ = unlink(marker.path)
    _ = rmdir(artifacts.path)
    _ = rmdir(root.path)
  }
  try JSONSerialization.data(withJSONObject: [
    "root": root.path, "uid": Int(getuid()),
    "purpose": "isolated-container-managed-G23",
  ])
  .write(to: marker, options: .withoutOverwriting)
  let descriptor = open(disk.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
  try #require(descriptor >= 0)
  defer { _ = Darwin.close(descriptor) }
  try #require(ftruncate(descriptor, 8 << 30) == 0)
  let device = try BlockDevice(path: disk.path)
  defer {
    do { try device.close() } catch {
      Issue.record("Disk close failed: \(error)", severity: .error)
    }
  }
  let fixture = RingFixture()
  fixture.store(UInt32(8), 1024)
  fixture.store(UInt64.max, 1032)
  fixture.bytes.storeBytes(of: UInt8(0xa5), toByteOffset: 3072, as: UInt8.self)
  let count = try device.process(
    [
      GuestBuffer(address: 1024, size: 16, writable: false),
      GuestBuffer(address: 2048, size: 20, writable: true),
      GuestBuffer(address: 3072, size: 1, writable: true),
    ], memory: fixture.memory)
  #expect(count == 1)
  #expect(fixture.bytes.load(fromByteOffset: 3072, as: UInt8.self) == 2)
  var diskBytes = [UInt8](repeating: 1, count: 512)
  #expect(pread(descriptor, &diskBytes, diskBytes.count, 0) == 512)
  #expect(diskBytes.allSatisfy { $0 == 0 })
}
