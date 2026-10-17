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
    var lease: SupervisionLease?
    do {
      lease = try SupervisionLease.install()
      try await run()
      try await lease?.close()
    } catch {
      do { try await lease?.close() } catch { print("SUPERVISOR_LEASE_CLOSE_FAIL \(error)") }
      print("CONTAINER_NATIVE_FAIL \(error)")
      exit(1)
    }
  }
  static func run() async throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count >= 5 else { throw Failure.arguments }
    let reporting = [
      "memory-reporting", "continuous-pressure-reporting", "continuous-pressure-reporting-small-boot",
    ].contains(args[4])
    let pressureWide = [
      "continuous-pressure-wide", "continuous-pressure-protected", "continuous-pressure-reporting",
      "continuous-pressure-reporting-small-boot",
    ]
      .contains(args[4])
    guard
      args.count == 5 && ["smoke", "start-refusal"].contains(args[4])
        || [6, 8].contains(args.count)
          && [
            "memory", "memory-reporting", "held", "alias", "crash", "recover", "adaptive",
            "adaptive-busy",
            "continuous", "continuous-cancel", "continuous-cancel-release", "continuous-soak",
            "continuous-stop",
            "continuous-churn",
            "continuous-expire", "continuous-expired-stop", "continuous-unsettled",
            "continuous-sustained",
            "continuous-pressure-wide",
            "continuous-pressure-protected",
            "continuous-pressure-reporting",
            "continuous-pressure-reporting-small-boot",
            "continuous-uart", "memory-wide",
            "memory-boot-wide",
          ].contains(args[4])
    else { throw Failure.arguments }
    guard !(pressureWide || reporting) || args.count == 8 else {
      throw Failure.arguments
    }
    if args.count == 8 {
      guard args[6] == "--boot-directory",
        [
          "memory", "memory-reporting", "adaptive", "continuous", "continuous-sustained",
          "memory-wide",
          "memory-boot-wide", "continuous-pressure-wide", "continuous-pressure-protected",
          "continuous-pressure-reporting",
          "continuous-pressure-reporting-small-boot",
          "crash", "recover",
        ].contains(args[4])
      else { throw Failure.arguments }
    }
    let output = URL(filePath: args[3])
    guard !FileManager.default.fileExists(atPath: output.path) else { throw Failure.arguments }
    try FileManager.default.createDirectory(
      at: output, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    if args[4] == "start-refusal" {
      try await LifecycleCheck.run(args: args, output: output)
      return
    }
    guard let cpus = Int(ProcessInfo.processInfo.environment["SWIFTOS_LAB_CPUS"] ?? "2"),
      (1...4).contains(cpus)
    else { throw Failure.arguments }
    let geometry: NativeMemoryGeometry
    switch args[4] {
    case "memory-wide", "continuous-pressure-wide", "continuous-pressure-protected",
      "continuous-pressure-reporting":
      geometry = try .init(bootBytes: 1024 << 20, dynamicBytes: 2 << 30)
    case "continuous-pressure-reporting-small-boot":
      geometry = try .init(bootBytes: 512 << 20, dynamicBytes: 2560 << 20)
    case "memory-boot-wide":
      geometry = try .init(bootBytes: 2 << 30, dynamicBytes: 256 << 20)
    default: geometry = .qualification
    }
    let resources: NativeBootResources?
    if args.count == 8 {
      let fd = open(args[7], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard fd >= 0 else { throw Failure.arguments }
      defer { Darwin.close(fd) }
      resources = try NativeBootResources(directoryDescriptor: fd)
    } else {
      resources = nil
    }
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    let manager: NativeVirtualMachineManager
    let policy: NativeExecutionPolicy =
      ["continuous-sustained", "continuous-pressure-wide", "continuous-pressure-protected",
        "continuous-pressure-reporting", "continuous-pressure-reporting-small-boot"]
        .contains(args[4])
      ? .sustained : .qualification
    if let resources {
      manager = NativeVirtualMachineManager(
        resources: resources, group: group, memoryGeometry: geometry, executionPolicy: policy,
        freePageReporting: reporting)
    } else {
      manager = NativeVirtualMachineManager(
        kernel: URL(filePath: args[0]), initfs: URL(filePath: args[1]),
        console: output.appending(path: "console.log"), held: args[4] == "held",
        aliasControl: [
          "alias", "adaptive-busy", "continuous-cancel", "continuous-cancel-release",
          "continuous-unsettled", "continuous-stop",
        ].contains(args[4]),
        group: group, memoryGeometry: geometry, executionPolicy: policy)
    }
    let links = try (0..<2).map { try IsolatedNetwork(index: $0) }
    let peers = links.map { EthernetPeer(link: $0) }
    let peerTasks = peers.map { peer in Task { try await peer.run() } }
    let serverOutput = BoundedOutput()
    let capacityLauncher = "/lab/startup-" + UUID().uuidString.lowercased()
    let launchMinimum = geometry.maximumBytes - (128 << 20)
    var launchReceipt: CapacityLaunchReceipt?
    let smoke = args[4] == "smoke"
    let container = try LinuxContainer(
      "swiftos-native",
      rootfs: .block(format: "ext4", source: resources?.mountSource ?? args[2], destination: "/"),
      vmm: manager, vm: .init(cpus: cpus, memoryInBytes: geometry.maximumBytes)
    ) { config in
      config.cpus = cpus
      config.memoryInBytes = (pressureWide ? 2816 : 896) << 20
      config.interfaces = links
      config.process.arguments =
        smoke
        ? ["/usr/bin/clickhouse", "--version"]
        : ["/usr/bin/clickhouse", "server", "--config-file=/lab/server.xml"]
      if pressureWide {
        config.process.arguments =
          [capacityLauncher, "--wait-capacity-exec", String(launchMinimum)]
          + config.process.arguments
      }
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
          // Observed96.1MiB control-plane working set thrashes below96MiB memory.high.
          // Keep16MiB headroom below the unchanged128MiB hard ceiling.
          try await agent.writeFile(
            path: "/sys/fs/cgroup/vminitd/memory.max", data: Data("134217728".utf8),
            flags: .init(create: false), mode: 0)
          try await agent.writeFile(
            path: "/sys/fs/cgroup/vminitd/memory.high", data: Data("117440512".utf8),
            flags: .init(create: false), mode: 0)
          let base = "/run/container/swiftos-native/rootfs"
          try await agent.mkdir(path: base + "/lab", all: true, perms: 0o700)
          try await agent.mkdir(path: base + "/data", all: true, perms: 0o700)
          try await agent.writeFile(
            path: base + "/lab/server.xml",
            data: Data(
              ClickHouseConfiguration.configuration(
                maximumMemoryBytes: (pressureWide ? 2560 : 640) << 20,
                memoryObserverIntervalSeconds: args[4] == "continuous-pressure-wide" ? 1 : 15
              ).utf8),
            flags: .init(create: true), mode: 0o600)
          try await agent.writeFile(
            path: base + "/lab/users.xml", data: Data(ClickHouseConfiguration.users.utf8),
            flags: .init(create: true), mode: 0o600)
          if pressureWide {
            _ = try await uploadProbe(
              URL(filePath: args[5]), path: base + capacityLauncher, agent: agent)
          }
          try await agent.close()
        } catch {
          try? await agent.close()
          throw error
        }
      }
      try await container.start()
      print("CONTAINER_STARTED")
      fflush(nil)
      if pressureWide {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while launchReceipt == nil {
          let transcript = serverOutput.text
          let lines = transcript.split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast()
          if let line = lines.first(where: {
            $0.hasPrefix("CAPACITY_READY ")
          }) {
            guard
              let receipt = CapacityLaunchReceipt(
                line: Substring(line + "\n"), minimum: launchMinimum,
                maximum: geometry.maximumBytes)
            else { throw Failure.check("invalid capacity startup receipt") }
            launchReceipt = receipt
          }
          // Preserve a completed receipt for diagnostics, but never admit past the host fence.
          guard !serverOutput.overflowed, ContinuousClock.now < deadline else {
            throw Failure.check("capacity startup deadline/overflow")
          }
          if transcript.contains("CANARY_FAIL") {
            throw Failure.check("capacity startup guest failure " + String(transcript.prefix(512)))
          }
          if launchReceipt == nil {
            try await Task.sleep(for: .milliseconds(20))
          }
        }
      }
      if smoke {
        let status = try await container.wait(timeoutInSeconds: 10)
        guard status.exitCode == 0, serverOutput.text.contains("ClickHouse") else {
          throw Failure.check("version " + serverOutput.text)
        }
        checked = true
      } else {
        checked = try await workload(
          container: container, vm: vm, output: output, probe: URL(filePath: args[5]), mode: args[4]
        )
        try await container.kill(.term)
        let status = try await container.wait(timeoutInSeconds: 10)
        guard status.exitCode == 0 else { throw Failure.check("server-exit") }
      }
    } catch { primary = String(describing: error) }
    for peer in peers { peer.stop() }
    for task in peerTasks {
      do { try await task.value } catch { cleanup.append("peer-stop \(error)") }
    }
    let stopping = Task { @concurrent in
      var failures: [String] = []
      do { try await container.stop() } catch { failures.append("container-stop \(error)") }
      if let vm = manager.instance {
        do { try await vm.stop() } catch { failures.append("vm-stop \(error)") }
      }
      do { try await group.shutdownGracefully() } catch { failures.append("group-stop \(error)") }
      return failures
    }
    cleanup += await stopping.value
    for link in links {
      do { try link.close() } catch { cleanup.append("link-close \(error)") }
    }
    let native = manager.instance?.result ?? Data()
    try native.write(to: output.appending(path: "native.json"), options: .withoutOverwriting)
    let result: [String: Any] = [
      "primaryError": primary, "cleanupErrors": cleanup,
      "bootResourceMode": resources == nil ? "legacy-research-paths" : "descriptor-pinned",
      "capabilityConsoleName": resources?.consoleName as Any? ?? NSNull(),
      "networkEchoes": peers.map(\.echoed),
      "checked": checked, "serverOutput": serverOutput.text,
      "bootBytes": geometry.bootBytes, "dynamicCapacityBytes": geometry.dynamicBytes,
      "controlPlaneHighBytes": 112 << 20, "controlPlaneMaximumBytes": 128 << 20,
      "capacityLaunchTotalBytes": launchReceipt.map { $0.totalBytes as Any } ?? NSNull(),
      "capacityLaunchElapsedNanoseconds": launchReceipt.map { $0.elapsedNanoseconds as Any }
        ?? NSNull(),
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
