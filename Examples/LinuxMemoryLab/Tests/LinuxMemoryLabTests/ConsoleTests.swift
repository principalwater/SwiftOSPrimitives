import Containerization
import Darwin
import Foundation
import NIOPosix
import Testing

@testable import NativeLinuxVMM

@Test(.serialized, arguments: [false, true])
func failedStartPreservesConsoleAndRetiresPartialAttachments(_ closedNIC: Bool) async throws {
  let temporary = try #require(ProcessInfo.processInfo.environment["TMPDIR"])
  let root = URL(filePath: temporary, directoryHint: .isDirectory)
    .appending(path: UUID().uuidString)
  let artifacts = root.appending(path: "artifacts")
  let marker = root.appending(path: "OWNER.json")
  let disk = artifacts.appending(path: "clickhouse-run-console.ext4")
  let initfs = artifacts.appending(path: "initfs.ext4")
  let console = root.appending(path: "console.log")
  try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
  defer {
    for file in [console, disk, initfs, marker] { _ = unlink(file.path) }
    _ = rmdir(artifacts.path)
    _ = rmdir(root.path)
  }
  try JSONSerialization.data(withJSONObject: [
    "root": root.path, "uid": Int(getuid()), "purpose": "isolated-container-managed-G23",
  ]).write(to: marker, options: .withoutOverwriting)
  for (file, size) in [(disk, Int64(8 << 30)), (initfs, Int64(4096))] {
    let descriptor = open(file.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    try #require(descriptor >= 0)
    defer { _ = Darwin.close(descriptor) }
    try #require(ftruncate(descriptor, size) == 0)
  }
  let sentinel = Data("existing console must survive a failed start\n".utf8)
  try sentinel.write(to: console, options: .withoutOverwriting)
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  do {
    let manager = NativeVirtualMachineManager(
      kernel: root.appending(path: "missing-kernel"), initfs: initfs,
      console: console, group: group)
    let links = try [IsolatedNetwork(), IsolatedNetwork(index: 1)]
    defer { for link in links { try? link.close() } }
    if closedNIC { try links[1].close() }
    let vm = try await manager.create(
      config: StandardVMConfig(
        configuration: .init(
          cpus: 1, memoryInBytes: 1152 << 20, interfaces: closedNIC ? links : [],
          mountsByID: [
            "research": [.block(format: "ext4", source: disk.path, destination: "/")]
          ])))
    await #expect(throws: NativeFailure.self) { try await vm.start() }
    let instance = try #require(manager.instance)
    let result = try #require(
      JSONSerialization.jsonObject(with: instance.result) as? [String: Any])
    #expect(try Data(contentsOf: console) == sentinel)
    if closedNIC {
      #expect(result["primaryError"] as? String == "state")
      #expect(throws: DeviceFailure.self) { _ = try links[0].send(Data(count: 14)) }
    } else {
      #expect((result["primaryError"] as? String)?.contains("console-open \(EEXIST)") == true)
    }
    #expect(result["workerJoined"] as? Bool == true)
    #expect(result["vmCreated"] as? Bool == false)
    #expect(result["cleanupErrors"] as? [String] == [])
    try await group.shutdownGracefully()
  } catch {
    try? await group.shutdownGracefully()
    throw error
  }
}
