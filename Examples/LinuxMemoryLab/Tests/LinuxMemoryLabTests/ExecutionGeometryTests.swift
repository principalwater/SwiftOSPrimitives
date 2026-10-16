import Foundation
import Testing

@testable import NativeLinuxVMM

@Test func executionPolicyPreservesFiniteDeadlineAndChecksSustainedStormBeforeRollover() throws {
  let began = ContinuousClock.now
  var finite = ExecutionFence(policy: .qualification, hasDisk: true, now: began)
  try finite.check(now: began.advanced(by: .seconds(119)), exits: 2_999_999)
  #expect(throws: Failure.self) {
    try finite.check(now: began.advanced(by: .seconds(120)), exits: 2_999_999)
  }
  var sustained = ExecutionFence(policy: .sustained, hasDisk: true, now: began)
  for second in 0...130 {
    try sustained.check(now: began.advanced(by: .seconds(second)), exits: second * 100_000)
  }
  #expect(throws: Failure.self) {
    try sustained.check(now: began.advanced(by: .seconds(131)), exits: 13_250_000)
  }
  var exhausted = ExecutionFence(policy: .qualification, hasDisk: true, now: began)
  #expect(throws: Failure.self) { try exhausted.check(now: began, exits: 3_000_000) }
}

@Test func geometryRefusesGPAOverlapAndAdvertisesActualDynamicWireCapacity() throws {
  for pair: (UInt64, UInt64) in [
    (128 << 20, 128 << 20), (4 << 30, 128 << 20), (1024 << 20, 0),
    (1024 << 20, 3 << 30), (1025 << 20, 128 << 20), (1024 << 20, 129 << 20),
    (UInt64.max, UInt64.max),
  ] {
    #expect(throws: NativeFailure.self) {
      _ = try NativeMemoryGeometry(bootBytes: pair.0, dynamicBytes: pair.1)
    }
  }
  let geometry = try NativeMemoryGeometry(bootBytes: 1024 << 20, dynamicBytes: 2 << 30)
  let device = MemoryDevice(held: false, geometry: geometry)
  let bytes = device.config()
  // The virtio-mem ABI has region, usable and requested sizes at24/32/48bytes.
  for offset in [24, 32, 48] {
    #expect(
      bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }
        == UInt64(0x8000_0000).littleEndian)
  }
  var request = Data(count: 24)
  request[0] = 3
  request[12] = 1
  request[17] = 4  //1024blocks of2MiB, independent wire literal.
  #expect(
    try device.request(request, quiescence: (true, 0, 2))
      == Data([0, 0, 0, 0, 0, 0, 0, 0, 1, 0]))
  request[16] = 1
  #expect(
    try device.request(request, quiescence: (true, 0, 2))
      == Data([3, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
  #expect(device.plugged == 0 && device.observations.isEmpty)
}
