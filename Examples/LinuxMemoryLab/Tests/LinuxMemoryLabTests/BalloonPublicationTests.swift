import Foundation
import NIOPosix
import Testing

@testable import NativeLinuxVMM

private func withBalloonControl(
  _ body: (NativeControl, NativeVirtualMachine, ClassicBalloonDevice, MemoryDevice) throws -> Void
) throws {
  let geometry = try NativeMemoryGeometry(bootBytes: 512 << 20, dynamicBytes: 128 << 20)
  let unused = URL(filePath: "/not-opened-by-balloon-publication-tests")
  let control = NativeControl(
    kernel: unused, initfs: unused, rootfs: unused, console: unused,
    held: false, alias: false, geometry: geometry, classicBallooning: true)
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  defer {
    do { try group.syncShutdownGracefully() } catch { Issue.record(error) }
  }
  let vm = NativeVirtualMachine(control: control, group: group, id: "unit", attachments: [])
  let balloon = try ClassicBalloonDevice(
    boot: 0x4000_0000..<0x6000_0000, dynamicBytes: geometry.dynamicBytes)
  let fixture = RingFixture()
  for (offset, value): (UInt64, UInt32) in [
    (0x70, 3), (0x20, 5), (0x24, 1), (0x20, 1), (0x70, 15),
  ] { _ = try balloon.transport.write(offset, value, memory: fixture.memory) }
  control.state.withLock {
    $0.running = true
    $0.memoryOwner = 7
    $0.balloonOwnerEpoch = balloon.ledger.epoch
    $0.plugged = geometry.dynamicBytes
    $0.publishBalloon(balloon)
  }
  try body(control, vm, balloon, MemoryDevice(held: false, geometry: geometry))
}

@Test func zeroApplicationPublishesItsBarrierAndAdmittedOwnerAtomically() throws {
  try withBalloonControl { control, vm, balloon, memory in
    control.state.withLock { $0.balloonZeroObserved = true }
    try vm.requestBalloon(bytes: 0, owner: 7)
    control.state.withLock {
      $0.memoryOwner = nil
      $0.memoryControlRetired = true
    }
    try control.applyBalloonRequest(to: balloon, memory: memory)
    let value = vm.balloonState
    #expect(value.requestGeneration == 1 && value.appliedGeneration == 1)
    #expect(value.targetBytes == 0 && value.actualBytes == 0 && value.ownedBytes == 0)
    #expect(!value.zeroTargetObserved && !value.settled)
    let application = try #require(vm.lastBalloonApplication)
    #expect(application.owner == 7 && application.generation == 1 && application.epoch == 1)
    #expect(application.targetBytes == value.targetBytes)
    let fixture = RingFixture()
    _ = try balloon.access(
      0x100, width: 4, write: nil, memory: memory, metadata: fixture.memory,
      payload: fixture.memory, quiescence: (true, 1, 1))
    control.state.withLock { $0.publishBalloon(balloon) }
    #expect(vm.balloonState.settled)
  }
}

@Test(arguments: ["epoch", "owner", "retired"])
func stalePositivePickupIsRejectedWithoutApplicationOrVMTermination(_ fault: String) throws {
  try withBalloonControl { control, vm, balloon, memory in
    try vm.requestBalloon(bytes: 128 << 20, owner: 7)
    control.state.withLock {
      if fault == "epoch" { $0.balloonRequestedEpoch += 1 }
      if fault == "owner" { $0.memoryOwner = nil }
      if fault == "retired" { $0.memoryControlRetired = true }
    }
    try control.applyBalloonRequest(to: balloon, memory: memory)
    try control.applyBalloonRequest(to: balloon, memory: memory)
    #expect(vm.lastBalloonApplication == nil)
    #expect(vm.balloonState.appliedGeneration == 0 && vm.balloonState.targetBytes == 0)
    let rejected = control.state.withLock {
      $0.balloonRejectedGeneration == 1 && $0.memoryControlRetired && !$0.stop && !$0.ended
    }
    #expect(rejected)
    let quarantined = control.memoryQuarantineRequested.load(ordering: .acquiring)
    #expect(quarantined)
  }
}

@Test(arguments: [false, true])
func stopAdoptsTheGovernorsExistingZeroWhilePendingOrDraining(_ applied: Bool) {
  let device = NativeBalloonState(
    epoch: 1, ready: true, targetBytes: applied ? 0 : 128 << 20,
    actualBytes: 64 << 20, ownedBytes: 64 << 20, quarantined: false,
    requestGeneration: 2, appliedGeneration: applied ? 2 : 1, zeroTargetObserved: false)
  #expect(
    NativeBalloonGovernor.admittedZeroGeneration(
      device: device, lastRequest: ["targetBytes": 0, "generation": 2]) == 2)
  #expect(
    NativeBalloonGovernor.admittedZeroGeneration(
      device: device, lastRequest: ["targetBytes": 0, "generation": 1]) == nil)
  #expect(
    NativeBalloonGovernor.admittedZeroGeneration(
      device: device, lastRequest: ["targetBytes": 128 << 20, "generation": 2]) == nil)
  #expect(NativeBalloonGovernor.admittedZeroGeneration(device: device, lastRequest: nil) == nil)
}

@Test func manualNilOwnerReachesBackingValidationWithoutFalseAuthorityRetirement() throws {
  try withBalloonControl { control, vm, balloon, memory in
    control.state.withLock { $0.memoryOwner = nil }
    try vm.requestBalloon(bytes: 128 << 20)
    // This fixture owns no HVF allocation: the correct next refusal is backing, not authority.
    #expect(throws: DeviceFailure.self) {
      try control.applyBalloonRequest(to: balloon, memory: memory)
    }
    let rejected = control.state.withLock { $0.balloonRejectedGeneration }
    let retired = control.state.withLock { $0.memoryControlRetired }
    #expect(rejected == 0 && !retired)
    #expect(vm.lastBalloonApplication == nil)
  }
}
