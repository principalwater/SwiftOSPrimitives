import AppleContainerMemory
import BoundedMemory
import Containerization
import ContainerizationExtras
import Darwin
import Foundation
import NIOPosix
import PageMemory
import Synchronization
@preconcurrency import Virtualization

/// A finite trusted workload, never a stock service or an externally reachable database.
@MainActor enum ClickHouseLab {
  static let mib: UInt64 = 1 << 20
  static let capacity: UInt64 = 2048 * mib
  static let imageReference = "docker.io/clickhouse/clickhouse-server@sha256:bdb5c911a23d92fd364e246ab20b5a0a485f00112f3663fa626b083fb46c146b"
  static let imageDigest = "sha256:bdb5c911a23d92fd364e246ab20b5a0a485f00112f3663fa626b083fb46c146b"

  static func prepare(_ output: URL) async throws {
    try ContainerMemoryLab.fresh(output)
    let store = try ImageStore(path: output.appending(path: "images"))
    let image = try await store.get(reference: imageReference, pull: true)
    guard image.digest == imageDigest else { throw LabFailure.invariant }
    _ = try await EXT4Unpacker(capacityInBytes: 8 << 30).unpack(
      image, for: .current, at: output.appending(path: "rootfs.ext4"))
    let rootfsHash = try ContainerMemoryLab.digest(
      output.appending(path: "rootfs.ext4"), maximumBytes: 8 << 30)
    try JSONEncoder().encode([
      "reference": imageReference, "digest": image.digest, "rootfsSHA256": rootfsHash,
    ])
      .write(to: output.appending(path: "images.json"), options: .withoutOverwriting)
    print("CLICKHOUSE_PREPARED")
  }

  static func run(
    prepared: URL, initfs: URL, kernel: URL, probeDirectory: URL, output: URL, adaptive: Bool
  ) async throws {
    let probeFile = probeDirectory.appending(path: "probe")
    let initialProbeHash = try ContainerMemoryLab.digest(probeFile)
    let initialInitHash = try ContainerMemoryLab.digest(initfs, maximumBytes: 1 << 30)
    guard try ContainerMemoryLab.digest(kernel)
      == "fb2cfb79eb1ae19447a85d75682d7fa5cfec97e24beb2609a492b806e8072c8d",
      try FileManager.default.contentsOfDirectory(atPath: probeDirectory.path) == ["probe"],
      probeDirectory.resolvingSymlinksInPath() == probeDirectory,
      !output.path.hasPrefix(probeDirectory.path + "/"),
      !output.path.hasPrefix(prepared.path + "/")
    else { throw LabFailure.arguments }
    var metadata = Data()
    try ContainerMemoryLab.scanInput(prepared.appending(path: "images.json"), maximumBytes: 65536) {
      metadata.append($0)
    }
    let image = try JSONDecoder().decode([String: String].self, from: metadata)
    guard image["digest"] == imageDigest else { throw LabFailure.arguments }
    try ContainerMemoryLab.fresh(output)
    let rootfs = output.appending(path: "rootfs.ext4")
    try FileManager.default.copyItem(at: prepared.appending(path: "rootfs.ext4"), to: rootfs)
    let rootfsHash = try ContainerMemoryLab.digest(rootfs, maximumBytes: 8 << 30)
    guard rootfsHash == image["rootfsSHA256"] else { throw LabFailure.arguments }
    let data = output.appending(path: "data")
    let configuration = output.appending(path: "configuration")
    for path in [data, configuration] {
      try FileManager.default.createDirectory(
        at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    try Data(serverConfiguration.utf8).write(to: configuration.appending(path: "config.xml"))
    try Data(userConfiguration.utf8).write(to: configuration.appending(path: "users.xml"))
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    let device = ContainerBalloonDevice(minimumResidentBytes: 1024 * mib)
    let guardVM = LabVMGuard(expectedMemoryBytes: capacity)
    let base = VZVirtualMachineManager(
      kernel: .init(path: kernel, platform: .linuxArm),
      initialFilesystem: .block(
        format: "ext4", source: initfs.path, destination: "/", options: ["ro"]), group: group)
    let manager = LabManager(base: base, device: device, share: guardVM)
    let serverOutput = BoundedOutput()
    let container = try LinuxContainer(
      "swiftos-clickhouse-lab",
      rootfs: .block(format: "ext4", source: rootfs.path, destination: "/"),
      vmm: manager, vm: .init(cpus: 1, memoryInBytes: capacity)
    ) { config in
      config.cpus = 1
      config.memoryInBytes = 1536 * mib
      config.interfaces = []
      config.hosts = .init(entries: [
        .init(ipAddress: "127.0.0.1", hostnames: ["localhost", "swiftos-clickhouse-lab"]),
      ])
      config.process.arguments = [
        "/usr/bin/clickhouse", "server", "--config-file=/lab/config.xml",
      ]
      config.process.stdout = serverOutput
      config.process.stderr = serverOutput
      config.process.noNewPrivileges = true
      config.mounts += [
        .share(source: configuration.path, destination: "/lab", options: ["ro"]),
        .share(source: data.path, destination: "/data", options: []),
        .share(source: probeDirectory.path, destination: "/probe", options: ["ro"]),
      ]
      config.bootLog = .file(path: output.appending(path: "boot.log"), append: false)
    }
    var instance: VZVirtualMachineInstance?
    var agentProcess: LinuxProcess?
    var probe: ProbeChannel?
    var primary = ""
    var cleanupErrors: [String] = []
    var samples: [[String: Any]] = []
    var hostSamples: [[String: Any]] = []
    var commands: [[String: Any]] = []
    var requests: [[String: UInt64]] = []
    var forceResult = ""
    var cleanupComplete = false
    var inFlightSQL: Task<String, any Error>?
    var integrityPassed = false
    let began = ContinuousClock.now
    do {
      try await container.create()
      instance = guardVM.instance
      guard instance != nil else { throw LabFailure.invariant }
      try await container.start()
      // SQL availability, not mere process creation, is the server-ready boundary.
      var ready = false
      for attempt in 0..<20 {
        do {
          let text = try await sql(container, id: "ready-\(attempt)", query: "SELECT 1")
          guard text.trimmingCharacters(in: .whitespacesAndNewlines) == "1" else {
            throw LabFailure.invariant
          }
          ready = true
          break
        } catch {
          if attempt == 19 { throw error }
          try await Task.sleep(for: .milliseconds(250))
        }
      }
      guard ready else { throw LabFailure.invariant }
      let input = CommandInput()
      let capture = ProbeOutput()
      let endpoint = ProbeChannel(input: input, output: capture, began: began)
      probe = endpoint
      let agent = try await container.exec("memory-agent") { config in
        config.arguments = ["/probe/probe", "--agent"]
        config.stdin = input
        config.stdout = capture
        config.stderr = capture
        config.noNewPrivileges = true
        config.capabilities = .init(
          capabilities: LinuxCapabilities.defaultOCICapabilities.effective + [.sysRawio, .sysAdmin])
      }
      agentProcess = agent
      try await agent.start()
      try await endpoint.ready(expectedDriver: "bound:")
      guard let budget = BalloonBudget(
        installedBytes: capacity, minimumResidentBytes: 1024 * mib,
        granuleBytes: mib, maximumStepBytes: 128 * mib),
        var controller = BalloonController(
          budget: budget, epoch: 1, guestReserveBytes: 512 * mib, hysteresisBytes: 64 * mib,
          maximumObservationAgeNanoseconds: 3_000_000_000, cooldownNanoseconds: 200_000_000,
          completionTimeoutNanoseconds: 10_000_000_000)
      else { throw LabFailure.invariant }
      defer { controller.retire() }
      let phases: [(String, String?)] = [
        ("idle-before", nil),
        ("schema", "CREATE TABLE events (shard UInt8, id UInt32, payload String) "
          + "ENGINE=MergeTree ORDER BY (shard,id)"),
      ] + (0..<8).map { batch in
        ("insert-\(batch)", "INSERT INTO events SELECT toUInt8(number % 8), "
          + "toUInt32(number + \(batch * 100000)), "
          + "repeat(leftPad(hex(cityHash64(number + \(batch * 100000))),16,'0'),8) FROM numbers(100000)")
      } + [
        ("idle-ingested", nil),
        ("hash-aggregate", "SELECT uniqExact(payload), sum(id) FROM events WHERE shard >= 0 LIMIT 1"),
        ("array-sort", "SELECT length(arraySort(groupArray(payload))) "
          + "FROM events WHERE shard >= 0 LIMIT 1"),
        ("idle-after-query", nil),
        ("allocator-purge", "SYSTEM JEMALLOC PURGE"),
        ("idle-after-purge", nil),
        ("integrity", "SELECT count(),sum(id),countIf(length(payload)=128 AND payload="
          + "repeat(leftPad(hex(cityHash64(toUInt64(id))),16,'0'),8)),uniqExact(id),min(id),max(id) "
          + "FROM events WHERE shard >= 0 LIMIT 1"),
      ]
      for (index, phase) in phases.enumerated() {
        let started = endpoint.now
        var finished = phase.1 == nil
        if let query = phase.1 {
          inFlightSQL = Task { @MainActor in
            defer { finished = true }
            return try await sql(container, id: "phase-\(index)", query: query)
          }
        }
        let end = ContinuousClock.now.advanced(by: phase.1 == nil ? .seconds(4) : .seconds(30))
        repeat {
          try Task.checkCancellation()
          let observation = try await endpoint.observe("S")
          guard UInt64(observation.actualPFNs) * 4096 <= capacity - 1024 * mib,
            UInt64(observation.requestedPFNs) * 4096 <= capacity - 1024 * mib,
            observation.total > 0, observation.total <= capacity else { throw LabFailure.invariant }
          if adaptive {
            try controller.checkDeadline(nowNanoseconds: endpoint.now)
            let sample = BalloonController.Observation(
              epoch: 1, sequence: observation.sequence,
              capturedAtNanoseconds: observation.capturedAtNanoseconds,
              actualResidentBytes: capacity - UInt64(observation.actualPFNs) * 4096,
              requestedResidentBytes: capacity - UInt64(observation.requestedPFNs) * 4096,
              guestAvailableBytes: observation.available, hostResidentLimitBytes: capacity,
              hostUnderPressure: false, guestUnderPressure: false)
            if let request = try controller.observe(sample, nowNanoseconds: endpoint.now) {
              _ = try await device.request(request.targetResidentBytes)
              let delivered = endpoint.now
              try controller.didApply(
                request, afterObservationSequence: endpoint.sequence, atNanoseconds: delivered)
              requests.append([
                "initial": request.initialResidentBytes, "target": request.targetResidentBytes,
                "sequence": request.sequence, "issuedAt": request.issuedAtNanoseconds,
                "deliveredAt": delivered,
              ])
            }
          } else {
            guard observation.actualPFNs == 0, observation.requestedPFNs == 0 else {
              throw LabFailure.invariant
            }
          }
          // Extra telemetry cannot delay the controller's observation/delivery boundary.
          let statistics = try await container.statistics(categories: [.memory, .cpu, .memoryEvents])
          guard let memory = statistics.memory, let cpu = statistics.cpu,
            let events = statistics.memoryEvents, events.oom == 0, events.oomKill == 0,
            memory.limitBytes == 1536 * mib else { throw LabFailure.invariant }
          samples.append([
            "phase": phase.0, "sequence": observation.sequence,
            "capturedAt": observation.capturedAtNanoseconds, "returnedAt": endpoint.now,
            "guestMemTotal": observation.total,
            "available": observation.available, "requestedPFNs": observation.requestedPFNs,
            "actualPFNs": observation.actualPFNs,
            "containerUsageBytes": memory.usageBytes, "containerAnonBytes": memory.anon,
            "containerCacheBytes": memory.cacheBytes, "containerLimitBytes": memory.limitBytes,
            "cpuUsageMicroseconds": cpu.usageUsec, "cpuThrottledMicroseconds": cpu.throttledTimeUsec,
            "oomEvents": events.oom, "oomKillEvents": events.oomKill,
          ])
          if endpoint.sequence % 10 == 0 {
            try checkDiskUsage(data, bootLog: output.appending(path: "boot.log"))
            let own = try ProcessMemorySnapshot.capture()
            var cpu = timespec()
            guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &cpu) == 0,
              cpu.tv_sec >= 0, cpu.tv_nsec >= 0, cpu.tv_nsec < 1_000_000_000 else {
              throw LabFailure.invariant
            }
            var row: [String: Any] = [
              "capturedAt": endpoint.now, "phase": phase.0, "residentBytes": own.residentBytes,
              "cpuTimeNanoseconds": UInt64(cpu.tv_sec) * 1_000_000_000 + UInt64(cpu.tv_nsec),
            ]
            if let footprint = own.physicalFootprintBytes { row["physicalFootprintBytes"] = footprint }
            hostSamples.append(row)
          }
          if phase.1 != nil, finished, controller.pendingRequest == nil { break }
          try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < end
        // Idle is a sampling window; an in-flight request retains its own sticky10s deadline.
        guard finished, phase.1 == nil || controller.pendingRequest == nil else {
          throw LabFailure.deadline
        }
        let answer: String
        if let task = inFlightSQL {
          answer = try await task.value
          inFlightSQL = nil
        } else { answer = "idle" }
        if phase.0 == "integrity" {
          guard answer.trimmingCharacters(in: .whitespacesAndNewlines)
            == "800000\t319999600000\t800000\t800000\t0\t799999" else {
              throw SQLFailure.server("Integrity refusal: " + answer)
            }
          integrityPassed = true
        }
        let serverMetrics = try await sql(
          container, id: "metrics-\(index)", query:
            "SELECT metric,value FROM system.asynchronous_metrics "
            + "WHERE metric IN ('MemoryResident','jemalloc.resident','jemalloc.allocated') "
            + "ORDER BY metric LIMIT 16")
        commands.append([
          "serverMetrics": serverMetrics,
          "phase": phase.0, "query": phase.1 ?? "", "answer": answer,
          "startedAt": started, "endedAt": endpoint.now,
        ])
        try JSONSerialization.data(withJSONObject: [
          "complete": false, "lastPhase": phase.0, "completedCommands": commands.count,
          "observations": samples.count, "requests": requests.count,
        ], options: [.sortedKeys])
          .write(to: output.appending(path: "progress.json"), options: .atomic)
      }
      guard controller.pendingRequest == nil else { throw LabFailure.deadline }
      let metrics = try await sql(
        container, id: "final-metrics", query:
          "SELECT metric,value FROM system.asynchronous_metrics "
          + "WHERE metric IN ('MemoryResident','MemoryVirtual','jemalloc.resident',"
          + "'jemalloc.allocated','jemalloc.retained','OSMemoryAvailable','OSMemoryTotal') "
          + "ORDER BY metric LIMIT 32")
      commands.append(["phase": "server-metrics", "answer": metrics])
      let version = try await sql(container, id: "version", query: "SELECT version()")
      commands.append(["phase": "version", "answer": version])
    } catch { primary = String(describing: error) }
    device.retire()
    let ownedInstance = instance ?? guardVM.instance
    let watchdog = Task { @MainActor in
      do { try await Task.sleep(for: .seconds(10)) } catch { return }
      guard !cleanupComplete else { return }
      do {
        forceResult = String(describing: try await device.retireAndStop())
        probe?.close()
      }
      catch { forceResult = "ERROR: \(error)" }
    }
    let stopping = Task { @MainActor in
      if let probe, let agentProcess {
        var quitClean = true
        do { try await probe.quit() } catch {
          cleanupErrors.append("diagnostic quit: \(error)")
          quitClean = false
        }
        probe.close()
        if !quitClean {
          do { try await agentProcess.kill(.kill) } catch {
            cleanupErrors.append("diagnostic kill: \(error)")
          }
        }
        do {
          let status = try await agentProcess.wait(timeoutInSeconds: 3)
          guard status.exitCode == 0 else { throw LabFailure.invariant }
        } catch { cleanupErrors.append("diagnostic wait: \(error)") }
        do { try await agentProcess.delete() } catch {
          cleanupErrors.append("diagnostic delete: \(error)")
        }
      } else { probe?.close() }
      do {
        try await container.kill(.term)
        let status = try await container.wait(timeoutInSeconds: 8)
        guard status.exitCode == 0 else { throw LabFailure.invariant }
      } catch { cleanupErrors.append("server: \(error)") }
      do { try await container.stop() } catch { cleanupErrors.append("runtime: \(error)") }
      if let task = inFlightSQL {
        _ = await task.result
        inFlightSQL = nil
      }
      if let ownedInstance, ownedInstance.state == .running {
        do { try await ownedInstance.stop() } catch { cleanupErrors.append("VM: \(error)") }
      }
      do { try await group.shutdownGracefully() } catch { cleanupErrors.append("NIO: \(error)") }
      cleanupComplete = true
    }
    await stopping.value
    watchdog.cancel()
    await watchdog.value
    let stopped = await ContainerMemoryLab.nativeStopped(ownedInstance)
    let finalProbeHash = try ContainerMemoryLab.digest(probeFile)
    let finalInitHash = try ContainerMemoryLab.digest(initfs, maximumBytes: 1 << 30)
    let exercised = !requests.isEmpty && samples.contains {
      ($0["actualPFNs"] as? UInt32 ?? 0) > 0
    }
    let checks: [String: Bool] = [
      "primaryClean": primary.isEmpty, "cleanupClean": cleanupErrors.isEmpty,
      "stopped": stopped, "cleanupJoined": cleanupComplete, "noForcedStop": forceResult.isEmpty,
      "probeUnchanged": finalProbeHash == initialProbeHash,
      "initfsUnchanged": finalInitHash == initialInitHash,
      "nativeVMConfiguration": guardVM.resources?.networkDevices == 0
        && guardVM.resources?.memory == capacity && guardVM.resources?.cpus == 1,
      "integrity": integrityPassed,
      "adaptiveExercised": !adaptive || exercised, "consoleBounded": !serverOutput.overflowed,
    ]
    let accepted = checks.values.allSatisfy { $0 }
    let result: [String: Any] = [
      "verdict": accepted ? "pass" : "fail", "checks": checks,
      "adaptive": adaptive, "imageReference": imageReference, "imageDigest": imageDigest,
      "initialRootfsSHA256": rootfsHash, "initfsSHA256": initialInitHash,
      "probeSHA256": initialProbeHash,
      "agentTranscript": probe?.transcript ?? [],
      "capacityBytes": capacity, "minimumResidentBytes": 1024 * mib,
      "reserveBytes": 512 * mib, "workloadLimitBytes": 1536 * mib,
      "observedVMCPUs": guardVM.resources?.cpus ?? -1,
      "observedVMInstalledBytes": guardVM.resources?.memory ?? 0,
      "networkDevices": guardVM.resources?.networkDevices ?? -1,
      "requests": requests, "samples": samples, "commands": commands,
      "hostControllerSamples": hostSamples,
      "hostControllerCounterScope": "self only; excludes unknown VZ service backing",
      "primaryError": primary, "cleanupErrors": cleanupErrors, "stopped": stopped,
      "cleanupJoined": cleanupComplete, "forceResult": forceResult,
      "physicalReleasedBytes": NSNull(),
      "physicalReleaseQualification": "VZ backing unknown; no host release credit/lending",
      "serverConsole": serverOutput.text,
    ]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appending(path: "result.json"), options: .withoutOverwriting)
    guard accepted else { throw LabFailure.invariant }
    print("CLICKHOUSE_MEMORY_LAB_PASS \(adaptive ? "adaptive" : "held")")
  }

  private static func sql(_ container: LinuxContainer, id: String, query: String) async throws
    -> String
  {
    let capture = BoundedOutput()
    let process = try await container.exec(id) { config in
      config.arguments = [
        "/usr/bin/clickhouse", "client", "--host=127.0.0.1", "--port=9000",
        "--receive_timeout=25", "--send_timeout=5", "--connect_timeout=2",
        "--max_threads=1", "--max_memory_usage=536870912", "--max_execution_time=20",
        "--max_rows_to_read=4000000", "--max_result_rows=1000", "--query", query,
      ]
      config.stdout = capture
      config.stderr = capture
      config.noNewPrivileges = true
    }
    let status: ExitStatus
    do {
      try await process.start()
      status = try await process.wait(timeoutInSeconds: 28)
    } catch {
      let failures = await Task {
        var failures: [String] = []
        do { try await process.kill(.kill) } catch { failures.append("kill: \(error)") }
        do { try await process.delete() } catch { failures.append("delete: \(error)") }
        return failures
      }.value
      throw SQLFailure.process(String(describing: error), failures)
    }
    try await Task { try await process.delete() }.value
    guard !capture.overflowed else { throw SQLFailure.outputLimit }
    guard status.exitCode == 0 else { throw SQLFailure.server(capture.text) }
    return capture.text
  }

  private static func checkDiskUsage(_ data: URL, bootLog: URL) throws {
    let size = try bootLog.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= 8 << 20,
      let files = FileManager.default.enumerator(
        at: data, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
    else { throw LabFailure.invariant }
    var total = 0
    var count = 0
    for case let file as URL in files {
      count += 1
      guard count <= 4096 else { throw LabFailure.invariant }
      let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      if values.isRegularFile == true {
        let bytes = values.fileSize ?? 0
        guard bytes >= 0, bytes <= (512 << 20) - total else { throw LabFailure.invariant }
        total += bytes
      }
    }
  }

  private enum SQLFailure: Error { case server(String), process(String, [String]), outputLimit }
  private static let serverConfiguration = """
    <clickhouse>
      <logger><level>debug</level><log>/data/server.log</log>
        <errorlog>/data/server.err.log</errorlog><size>5M</size><count>1</count></logger>
      <path>/data/store/</path><tmp_path>/data/tmp/</tmp_path>
      <user_files_path>/data/user_files/</user_files_path><users_config>/lab/users.xml</users_config>
      <listen_host>127.0.0.1</listen_host><tcp_port>9000</tcp_port>
      <max_server_memory_usage>1073741824</max_server_memory_usage>
      <max_thread_pool_size>64</max_thread_pool_size><background_pool_size>2</background_pool_size>
      <background_schedule_pool_size>2</background_schedule_pool_size>
      <background_streaming_schedule_pool_size>1</background_streaming_schedule_pool_size>
      <background_move_pool_size>1</background_move_pool_size>
      <background_fetches_pool_size>1</background_fetches_pool_size>
      <background_common_pool_size>1</background_common_pool_size>
      <background_message_broker_schedule_pool_size>1</background_message_broker_schedule_pool_size>
      <background_distributed_schedule_pool_size>1</background_distributed_schedule_pool_size>
      <background_buffer_flush_schedule_pool_size>1</background_buffer_flush_schedule_pool_size>
      <merge_tree>
        <number_of_free_entries_in_pool_to_execute_mutation>0</number_of_free_entries_in_pool_to_execute_mutation>
        <number_of_free_entries_in_pool_to_lower_max_size_of_merge>0</number_of_free_entries_in_pool_to_lower_max_size_of_merge>
        <number_of_free_entries_in_pool_to_execute_optimize_entire_partition>0</number_of_free_entries_in_pool_to_execute_optimize_entire_partition>
      </merge_tree>
      <mark_cache_size>16777216</mark_cache_size><uncompressed_cache_size>16777216</uncompressed_cache_size>
      <mlock_executable>false</mlock_executable>
      <asynchronous_metrics_update_period_s>1</asynchronous_metrics_update_period_s>
    </clickhouse>
    """
  private static let userConfiguration = """
    <clickhouse>
      <profiles><default><max_memory_usage>536870912</max_memory_usage><max_threads>1</max_threads>
        <max_execution_time>20</max_execution_time><max_rows_to_read>4000000</max_rows_to_read>
        <max_result_rows>1000</max_result_rows></default></profiles>
      <users><default><password></password><profile>default</profile><quota>default</quota>
        <networks><ip>127.0.0.1</ip></networks></default></users>
      <quotas><default><interval><duration>3600</duration><queries>1000</queries>
        <errors>100</errors><result_rows>1000000</result_rows><read_rows>100000000</read_rows>
        <execution_time>300</execution_time></interval></default></quotas>
    </clickhouse>
    """
}
