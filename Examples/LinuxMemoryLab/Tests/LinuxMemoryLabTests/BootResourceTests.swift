import Containerization
import Darwin
import Darwin.membership
import Foundation
import NIOPosix
import Testing

@testable import NativeLinuxVMM

private final class BootFixture {
  var root: URL
  let initial: URL
  var directory: Int32
  init(base: String? = nil) throws {
    let temporary = try #require(
      base ?? ProcessInfo.processInfo.environment["SWIFTOS_BOOT_TEST_ROOT"]
        ?? ProcessInfo.processInfo.environment["TMPDIR"])
    root = URL(filePath: temporary).appending(path: "boot-" + UUID().uuidString)
    initial = root
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    try #require(directory >= 0)
    var retained = false
    defer {
      if !retained {
        Darwin.close(directory)
        try? FileManager.default.removeItem(at: root)
      }
    }
    var kernel = Data(count: 64)
    kernel.replaceSubrange(56..<60, with: [0x41, 0x52, 0x4d, 0x64])
    for (name, data) in [
      ("kernel", kernel), ("initfs.ext4", Data(count: 4096)),
      ("rootfs.ext4", Data(repeating: 0x5a, count: 4096)),
    ] {
      let path = root.appending(path: name)
      try data.write(to: path, options: .withoutOverwriting)
      try #require(chmod(path.path, 0o600) == 0)
    }
    retained = true
  }
  func closeDirectory() {
    if directory >= 0 {
      Darwin.close(directory)
      directory = -1
    }
  }
  deinit {
    closeDirectory()
    try? FileManager.default.removeItem(at: root)
    if root != initial { try? FileManager.default.removeItem(at: initial) }
  }
}

@Test func admittedBootFilesSurviveDirectoryAndFilePathReplacement() throws {
  let fixture = try BootFixture()
  let resources = try NativeBootResources(directoryDescriptor: fixture.directory)
  let expectedKernel = try Data(contentsOf: fixture.root.appending(path: "kernel"))
  let relocated = fixture.root.appendingPathExtension("moved")
  try FileManager.default.moveItem(at: fixture.root, to: relocated)
  fixture.root = relocated
  try FileManager.default.createDirectory(at: fixture.initial, withIntermediateDirectories: false)
  let decoy = fixture.initial.appending(path: "rootfs.ext4")
  try Data(repeating: 0x11, count: 4096).write(to: decoy, options: .withoutOverwriting)
  let original = relocated.appending(path: "rootfs.ext4")
  let retiredName = relocated.appending(path: "original.ext4")
  try FileManager.default.moveItem(at: original, to: retiredName)
  try Data(repeating: 0x22, count: 4096).write(to: original, options: .withoutOverwriting)
  try Data(repeating: 0xff, count: 64).write(to: relocated.appending(path: "kernel"))
  fixture.closeDirectory()
  let device = try BlockDevice(resources: resources, readOnly: false, executionPolicy: .sustained)
  defer { try? device.close() }
  let ring = RingFixture()
  ring.store(UInt32(1), 1024)
  ring.store(UInt64(0), 1032)
  memset(ring.bytes.advanced(by: 4096), 0x33, 512)
  let buffers = [
    GuestBuffer(address: 1024, size: 16, writable: false),
    GuestBuffer(address: 4096, size: 512, writable: false),
    GuestBuffer(address: 3072, size: 1, writable: true),
  ]
  #expect(try device.process(buffers, memory: ring.memory) == 1)
  #expect(try Data(contentsOf: retiredName).prefix(512) == Data(repeating: 0x33, count: 512))
  #expect(try Data(contentsOf: original) == Data(repeating: 0x22, count: 4096))
  #expect(try Data(contentsOf: decoy) == Data(repeating: 0x11, count: 4096))
  #expect(try resources.takeKernel() == expectedKernel)
  #expect(throws: NativeBootResources.Failure.self) { _ = try resources.takeKernel() }
  let console = FileHandle(
    fileDescriptor: try resources.duplicateConsole(), closeOnDealloc: true)
  try console.write(contentsOf: Data("pinned-console\n".utf8))
  try console.close()
  #expect(
    try Data(contentsOf: relocated.appending(path: resources.consoleName))
      == Data("pinned-console\n".utf8))
}

@Test func diskAttachmentRetainsExclusiveStorageUntilItsOwnClose() throws {
  let fixture = try BootFixture()
  var resources: NativeBootResources? = try .init(directoryDescriptor: fixture.directory)
  let firstConsole = try #require(resources?.consoleName)
  let device = try BlockDevice(
    resources: try #require(resources), readOnly: false, executionPolicy: .sustained)
  resources = nil
  let before = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted()
  #expect(throws: NativeBootResources.Failure.self) {
    _ = try NativeBootResources(directoryDescriptor: fixture.directory)
  }
  #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted() == before)
  try device.close()
  let reopened = try NativeBootResources(directoryDescriptor: fixture.directory)
  #expect(reopened.consoleName != firstConsole)
  #expect(try Data(contentsOf: fixture.root.appending(path: firstConsole)).isEmpty)
}

@Test(arguments: [
  "kernel-magic", "kernel-size", "init-alignment", "root-empty", "init-size",
  "root-symlink", "init-hardlink", "init-fifo", "directory-mode", "root-mode",
])
func invalidBootResourcesRefuseBeforeCreatingConsole(_ fault: String) throws {
  let fixture = try BootFixture()
  let kernel = fixture.root.appending(path: "kernel")
  let initfs = fixture.root.appending(path: "initfs.ext4")
  let rootfs = fixture.root.appending(path: "rootfs.ext4")
  switch fault {
  case "kernel-magic": try Data(count: 64).write(to: kernel)
  case "kernel-size", "init-alignment", "root-empty", "init-size":
    let path = fault == "kernel-size" ? kernel : fault == "root-empty" ? rootfs : initfs
    let bytes: Int64 =
      fault == "kernel-size"
      ? (64 << 20) + 1
      : fault == "init-size" ? (512 << 20) + 512 : fault == "root-empty" ? 0 : 513
    let fd = open(path.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    try #require(fd >= 0)
    defer { Darwin.close(fd) }
    try #require(ftruncate(fd, bytes) == 0)
  case "root-symlink":
    try FileManager.default.removeItem(at: rootfs)
    try FileManager.default.createSymbolicLink(at: rootfs, withDestinationURL: initfs)
  case "init-hardlink":
    try FileManager.default.linkItem(at: initfs, to: fixture.root.appending(path: "alias.ext4"))
  case "init-fifo":
    try FileManager.default.removeItem(at: initfs)
    try #require(mkfifo(initfs.path, 0o600) == 0)
  case "directory-mode": try #require(chmod(fixture.root.path, 0o755) == 0)
  default: try #require(chmod(rootfs.path, 0o644) == 0)
  }
  let before = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted()
  #expect(throws: NativeBootResources.Failure.self) {
    _ = try NativeBootResources(directoryDescriptor: fixture.directory)
  }
  #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted() == before)
}

@Test func capabilityMountIsExactAndBootOwnershipCannotBeReused() async throws {
  let fixture = try BootFixture()
  let resources = try NativeBootResources(directoryDescriptor: fixture.directory)
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  do {
    let manager = NativeVirtualMachineManager(resources: resources, group: group)
    func config(_ source: String) -> StandardVMConfig {
      .init(
        configuration: .init(
          cpus: 2, memoryInBytes: NativeMemoryGeometry.qualification.maximumBytes, interfaces: [],
          mountsByID: ["native": [.block(format: "ext4", source: source, destination: "/")]]))
    }
    await #expect(throws: NativeFailure.self) {
      _ = try await manager.create(config: config("/unadmitted/path.ext4"))
    }
    let vm = try await manager.create(config: config(resources.mountSource))
    #expect(vm.mounts["native"]?.first?.source == "/dev/vdb")
    let competing = NativeVirtualMachineManager(resources: resources, group: group)
    await #expect(throws: NativeBootResources.Failure.self) {
      _ = try await competing.create(config: config(resources.mountSource))
    }
    try await vm.stop()
    #expect(vm.state == .stopped)
    withExtendedLifetime(manager) {
      #expect(throws: NativeBootResources.Failure.self) { _ = try resources.takeKernel() }
      #expect(throws: NativeBootResources.Failure.self) {
        let descriptor = try resources.duplicateConsole()
        Darwin.close(descriptor)
      }
    }
    let reopened = try NativeBootResources(directoryDescriptor: fixture.directory)
    #expect(reopened.id != resources.id)
    try await group.shutdownGracefully()
  } catch {
    try? await group.shutdownGracefully()
    throw error
  }
}

@Test(arguments: ["directory", "kernel", "initfs.ext4", "rootfs.ext4"])
func extendedBootAccessRefusesBeforeCreatingConsole(_ target: String) throws {
  let fixture = try BootFixture()
  var filesystem = statfs()
  try #require(fstatfs(fixture.directory, &filesystem) == 0)
  try #require(filesystem.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) == 0)
  let descriptor =
    target == "directory"
    ? dup(fixture.directory)
    : openat(
      fixture.directory, target, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
  try #require(descriptor >= 0)
  defer { Darwin.close(descriptor) }
  var acl = acl_init(1)
  try #require(acl != nil)
  defer { if let acl { acl_free(UnsafeMutableRawPointer(acl)) } }
  var entry: acl_entry_t?
  try #require(acl_create_entry(&acl, &entry) == 0)
  let item = try #require(entry)
  try #require(acl_set_tag_type(item, ACL_EXTENDED_ALLOW) == 0)
  var group = UUID().uuid
  try #require(mbr_gid_to_uuid(getgid(), &group) == 0)
  try #require(acl_set_qualifier(item, &group) == 0)
  var permissions: acl_permset_t?
  try #require(acl_get_permset(item, &permissions) == 0)
  let granted = try #require(permissions)
  try #require(acl_add_perm(granted, ACL_READ_DATA) == 0)
  try #require(acl_add_perm(granted, ACL_WRITE_DATA) == 0)
  let access = try #require(acl)
  try #require(acl_set_fd_np(descriptor, access, ACL_TYPE_EXTENDED) == 0)
  let before = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted()
  #expect(throws: NativeBootResources.Failure.self) {
    _ = try NativeBootResources(directoryDescriptor: fixture.directory)
  }
  #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted() == before)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTOS_NOOWNERS_TEST_ROOT"] != nil))
func ignoredOwnersVolumeCannotSupplyPrivateBootAuthority() throws {
  let base = try #require(ProcessInfo.processInfo.environment["SWIFTOS_NOOWNERS_TEST_ROOT"])
  let fixture = try BootFixture(base: base)
  var filesystem = statfs()
  try #require(fstatfs(fixture.directory, &filesystem) == 0)
  try #require(filesystem.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) != 0)
  let before = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted()
  #expect(throws: NativeBootResources.Failure.self) {
    _ = try NativeBootResources(directoryDescriptor: fixture.directory)
  }
  #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted() == before)
}
