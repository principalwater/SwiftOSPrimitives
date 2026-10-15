import AppleContainerMemory
import ContainerizationExtras
import Foundation
import Testing
@preconcurrency import Virtualization

@testable import container_memory_lab

@Suite(.timeLimit(.minutes(1))) struct MemoryIntegrationTests {
  @Test func configurationPreservesForeignDeviceAndRefusesReuse() throws {
    let device = ContainerBalloonDevice(minimumResidentBytes: 256 << 20)
    var config = VZVirtualMachineConfiguration()
    config.memorySize = 512 << 20
    let allocator = Character.blockDeviceTagAllocator()
    try device.configureVZ(&config, allocator: allocator, storageDeviceCount: 0, mountsByID: [:])
    #expect(config.memoryBalloonDevices.count == 1)
    #expect(config.memoryBalloonDevices[0] is VZVirtioTraditionalMemoryBalloonDeviceConfiguration)
    #expect(throws: ContainerBalloonDevice.Failure.duplicateConfiguration) {
      try device.configureVZ(&config, allocator: allocator, storageDeviceCount: 0, mountsByID: [:])
    }
    let foreign = config.memoryBalloonDevices[0]
    #expect(throws: ContainerBalloonDevice.Failure.unexpectedDevice) {
      try ContainerBalloonDevice(minimumResidentBytes: 256 << 20).configureVZ(
        &config, allocator: allocator, storageDeviceCount: 0, mountsByID: [:])
    }
    #expect(config.memoryBalloonDevices.count == 1)
    #expect(config.memoryBalloonDevices[0] === foreign)
  }

  @Test func requestNeedsBoundLiveEpochAndValidGeometry() async throws {
    let device = ContainerBalloonDevice(minimumResidentBytes: 256 << 20)
    var config = VZVirtualMachineConfiguration()
    config.memorySize = 512 << 20
    try device.configureVZ(
      &config, allocator: Character.blockDeviceTagAllocator(), storageDeviceCount: 0,
      mountsByID: [:])
    for target: UInt64 in [0, 128 << 20, 256 << 20 | 1, 513 << 20] {
      await #expect(throws: ContainerBalloonDevice.Failure.invalidTarget) {
        try await device.request(target)
      }
    }
    await #expect(throws: ContainerBalloonDevice.Failure.unbound) {
      try await device.request(256 << 20)
    }
    device.retire()
    await #expect(throws: ContainerBalloonDevice.Failure.retired) {
      try await device.request(256 << 20)
    }
    #expect(throws: ContainerBalloonDevice.Failure.duplicateConfiguration) {
      try device.configureVZ(
        &config, allocator: Character.blockDeviceTagAllocator(), storageDeviceCount: 0,
        mountsByID: [:])
    }
  }

  @Test func unboundEmergencyStopStillClosesSetterAdmission() async throws {
    let device = ContainerBalloonDevice(minimumResidentBytes: 256 << 20)
    await #expect(throws: ContainerBalloonDevice.Failure.unbound) {
      try await device.retireAndStop()
    }
    await #expect(throws: ContainerBalloonDevice.Failure.retired) {
      try await device.request(256 << 20)
    }
    var config = VZVirtualMachineConfiguration()
    config.memorySize = 512 << 20
    #expect(throws: ContainerBalloonDevice.Failure.duplicateConfiguration) {
      try device.configureVZ(
        &config, allocator: Character.blockDeviceTagAllocator(), storageDeviceCount: 0,
        mountsByID: [:])
    }
  }

  @Test func framingHandlesFragmentationCloseAndRefusesOversize() throws {
    let output = ProbeOutput()
    try output.write(Data("PROBE_".utf8))
    #expect(try output.takeLine() == nil)
    try output.write(Data("DONE 1\nnext\n".utf8))
    output.close()
    #expect(try output.takeLine() == "PROBE_DONE 1")
    #expect(try output.takeLine() == "next")
    #expect(throws: LabFailure.disconnected) { try output.takeLine() }
    #expect(throws: LabFailure.framing) { try output.write(Data([10])) }
    let oversized = ProbeOutput()
    #expect(throws: LabFailure.framing) {
      try oversized.write(Data(repeating: 65, count: 16385))
    }
    let malformed = ProbeOutput()
    try malformed.write(Data([0, 10]))
    #expect(throws: LabFailure.framing) { try malformed.takeLine() }
  }

  @Test func commandQueueIsBoundedAndFinishes() async throws {
    let input = CommandInput()
    try input.send(Data("S 1\n".utf8))
    #expect(throws: LabFailure.disconnected) { try input.send(Data("S 2\n".utf8)) }
    var iterator = input.stream().makeAsyncIterator()
    #expect(await iterator.next() == Data("S 1\n".utf8))
    input.finish()
    #expect(await iterator.next() == nil)
    #expect(throws: LabFailure.disconnected) { try input.send(Data("S 3\n".utf8)) }
  }

  @Test func outputOverflowIsStickyAndPreservesAcceptedPrefix() throws {
    let output = BoundedOutput()
    try output.write(Data(repeating: 65, count: 1 << 20))
    #expect(!output.overflowed)
    #expect(throws: BoundedOutput.Failure.limit) { try output.write(Data([66])) }
    output.close()
    #expect(output.overflowed)
    #expect(output.text.utf8.count == 1 << 20)
    #expect(output.text.utf8.allSatisfy { $0 == 65 })
  }

  @MainActor @Test func closingEndpointInterruptsResponseWait() async {
    let endpoint = ProbeChannel(input: CommandInput(), output: ProbeOutput(), began: .now)
    endpoint.close()
    await #expect(throws: LabFailure.disconnected) {
      try await endpoint.ready(expectedDriver: "none")
    }
  }

  @MainActor @Test func protocolRejectsWrongSequenceAndDriverSuffix() async throws {
    let input = CommandInput()
    let output = ProbeOutput()
    let probe = ProbeChannel(input: input, output: output, began: .now)
    try output.write(Data("PROBE_READY 4096 1024 512 workload-extra\n".utf8))
    await #expect(throws: LabFailure.framing) { try await probe.ready(expectedDriver: "workload") }
    try output.write(Data("PROBE_OBS 2 1024 512 0 20 0 0\n".utf8))
    await #expect(throws: LabFailure.framing) { try await probe.observe("S") }
    probe.close()
  }

  @MainActor @Test func workloadProofRejectsRawIOAndWrongLimit() async throws {
    for reply in ["134217728 0000000000020000 1 0 0", "268435456 0 1 0 0"] {
      let input = CommandInput()
      let output = ProbeOutput()
      let probe = ProbeChannel(input: input, output: output, began: .now)
      try output.write(Data("PROBE_INFO 1 \(reply)\n".utf8))
      await #expect(throws: LabFailure.invariant) { try await probe.verifyWorkloadLimitsAndMount() }
      probe.close()
    }
    let input = CommandInput()
    let output = ProbeOutput()
    let probe = ProbeChannel(input: input, output: output, began: .now)
    try output.write(Data("PROBE_INFO 1 134217728 00000000a80425fb 1 0 0\n".utf8))
    try await probe.verifyWorkloadLimitsAndMount()
    probe.close()
  }

  @MainActor @Test func completeProtocolRoundtripPreservesSequenceAndFields() async throws {
    let input = CommandInput()
    let output = ProbeOutput()
    let probe = ProbeChannel(input: input, output: output, began: .now)
    var commands = input.stream().makeAsyncIterator()
    let features = String(repeating: "0", count: 64)
    try output.write(Data("PROBE_READY 4096 1024 512 bound:\(features)\n".utf8))
    try await probe.ready(expectedDriver: "bound:")
    try output.write(Data("PROBE_OBS 1 1024 512 0 20 3 3\n".utf8))
    let value = try await probe.observe("S")
    #expect(value.sequence == 1 && value.total == 1024 && value.available == 512)
    #expect(value.requestedPFNs == 3 && value.actualPFNs == 3 && value.residentPages == 0)
    #expect(await commands.next() == Data("S 1\n".utf8))
    try output.write(Data("PROBE_DONE 2\n".utf8))
    try await probe.quit()
    #expect(await commands.next() == Data("Q 2\n".utf8))
    probe.close()
    #expect(await commands.next() == nil)
  }
}
