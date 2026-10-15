import Containerization
import Darwin
import Foundation
import NIOPosix
import NativeLinuxVMM

@main struct Lab {
  enum Failure: Error {
    case arguments
    case check(String)
  }
  static func main() async {
    do { try await run() } catch {
      print("CONTAINER_NATIVE_FAIL \(error)")
      exit(1)
    }
  }
  static func run() async throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count >= 5 else { throw Failure.arguments }
    guard
      args.count == 5 && ["smoke", "start-refusal"].contains(args[4])
        || args.count == 6 && ["memory", "held", "alias"].contains(args[4])
    else { throw Failure.arguments }
    let output = URL(filePath: args[3])
    guard !FileManager.default.fileExists(atPath: output.path) else { throw Failure.arguments }
    try FileManager.default.createDirectory(
      at: output, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    if args[4] == "start-refusal" {
      try await LifecycleCheck.run(args: args, output: output)
      return
    }
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    let manager = NativeVirtualMachineManager(
      kernel: URL(filePath: args[0]), initfs: URL(filePath: args[1]),
      console: output.appending(path: "console.log"), held: args[4] == "held",
      aliasControl: args[4] == "alias", group: group)
    let serverOutput = BoundedOutput()
    let smoke = args[4] == "smoke"
    let container = try LinuxContainer(
      "swiftos-native",
      rootfs: .block(format: "ext4", source: args[2], destination: "/"),
      vmm: manager, vm: .init(cpus: 1, memoryInBytes: 1152 << 20)
    ) { config in
      config.cpus = 1
      config.memoryInBytes = 896 << 20
      config.interfaces = []
      config.process.arguments =
        smoke
        ? ["/usr/bin/clickhouse", "--version"]
        : ["/usr/bin/clickhouse", "server", "--config-file=/lab/server.xml"]
      config.process.environmentVariables += ["CLICKHOUSE_WATCHDOG_ENABLE=0"]
      config.process.stdout = serverOutput
      config.process.stderr = serverOutput
      config.process.noNewPrivileges = true
    }
    var primary = ""
    var cleanup: [String] = []
    var checked = false
    do {
      try await container.create()
      print("CONTAINER_CREATED")
      guard let vm = manager.instance else { throw Failure.check("instance") }
      if !smoke {
        let agent = try await vm.dialAgent()
        do {
          let base = "/run/container/swiftos-native/rootfs"
          try await agent.mkdir(path: base + "/lab", all: true, perms: 0o700)
          try await agent.mkdir(path: base + "/data", all: true, perms: 0o700)
          try await agent.writeFile(
            path: base + "/lab/server.xml", data: Data(ClickHouseConfiguration.configuration.utf8),
            flags: .init(create: true), mode: 0o600)
          try await agent.writeFile(
            path: base + "/lab/users.xml", data: Data(ClickHouseConfiguration.users.utf8),
            flags: .init(create: true), mode: 0o600)
          try await agent.close()
        } catch {
          try? await agent.close()
          throw error
        }
      }
      try await container.start()
      print("CONTAINER_STARTED")
      if smoke {
        let status = try await container.wait(timeoutInSeconds: 10)
        guard status.exitCode == 0, serverOutput.text.contains("ClickHouse") else {
          throw Failure.check("version " + serverOutput.text)
        }
        checked = true
      } else {
        checked = try await workload(
          container: container, vm: vm, output: output, probe: URL(filePath: args[5]))
        try await container.kill(.term)
        let status = try await container.wait(timeoutInSeconds: 10)
        guard status.exitCode == 0 else { throw Failure.check("server-exit") }
      }
    } catch { primary = String(describing: error) }
    let stopping = Task { @concurrent in
      var failures: [String] = []
      do { try await container.stop() } catch { failures.append("container-stop \(error)") }
      if let vm = manager.instance {
        do { try await vm.stop() } catch { failures.append("vm-stop \(error)") }
      }
      do { try await group.shutdownGracefully() } catch { failures.append("group-stop \(error)") }
      return failures
    }
    cleanup = await stopping.value
    let native = manager.instance?.result ?? Data()
    try native.write(to: output.appending(path: "native.json"), options: .withoutOverwriting)
    let result: [String: Any] = [
      "primaryError": primary, "cleanupErrors": cleanup,
      "checked": checked, "serverOutput": serverOutput.text,
      "serverOutputOverflow": serverOutput.overflowed, "physicalReleasedBytes": NSNull(),
    ]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appending(path: "result.json"), options: .withoutOverwriting)
    guard primary.isEmpty, cleanup.isEmpty, checked, !serverOutput.overflowed else {
      throw Failure.check(primary + " " + cleanup.joined(separator: ";"))
    }
    print("CONTAINER_NATIVE_PASS")
  }
}
