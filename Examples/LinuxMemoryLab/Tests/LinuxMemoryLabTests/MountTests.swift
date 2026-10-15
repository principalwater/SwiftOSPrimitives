import Containerization
import Foundation
import NIOPosix
import Testing

@testable import NativeLinuxVMM

@Test func defaultGuestMountsPreserveOCIOptionsAndRejectHostAttachments() async throws {
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  do {
    let root = Mount.block(format: "ext4", source: "/unused/research.ext4", destination: "/")
    let defaults = LinuxContainer.defaultMounts()
    let config = VMConfiguration(
      cpus: 1, memoryInBytes: 1152 << 20, interfaces: [],
      mountsByID: ["research": [root] + defaults])
    func manager() -> NativeVirtualMachineManager {
      NativeVirtualMachineManager(
        kernel: URL(filePath: "/unused/kernel"), initfs: URL(filePath: "/unused/initfs"),
        console: URL(filePath: "/unused/console"), group: group)
    }
    let vm = try await manager().create(config: StandardVMConfig(configuration: config))
    let actual = try #require(vm.mounts["research"])
    #expect(actual.first?.source == "/dev/vdb")
    #expect(actual.count == defaults.count + 1)
    for (attachment, mount) in zip(actual.dropFirst(), defaults) {
      #expect(attachment.type == mount.type)
      #expect(attachment.source == mount.source)
      #expect(attachment.destination == mount.destination)
      #expect(attachment.options == mount.options)
    }
    for unsupported in [
      Mount.block(format: "ext4", source: "/unused/extra.ext4", destination: "/extra"),
      Mount.share(source: "/unused/host-directory", destination: "/host"),
      Mount.sharedMount(name: "unattached-pod-volume", destination: "/shared"),
    ] {
      var invalid = config
      invalid.mountsByID["research", default: []].append(unsupported)
      await #expect(throws: NativeFailure.self) {
        _ = try await manager().create(config: StandardVMConfig(configuration: invalid))
      }
    }
    try await group.shutdownGracefully()
  } catch {
    try? await group.shutdownGracefully()
    throw error
  }
}
