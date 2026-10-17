import BoundedMemory
import Containerization
import Darwin
import Foundation
import NativeLinuxVMM
import PageMemory

extension Lab {
  struct RunningSQL: Sendable {
    let process: LinuxProcess
    let output: BoundedOutput

    func discard() async -> [String] {
      await Task { @concurrent in
        var errors: [String] = []
        do { try await process.kill(.kill) } catch { errors.append("kill \(error)") }
        do { try await process.delete() } catch { errors.append("delete \(error)") }
        return errors
      }.value
    }

    func finish() async throws -> String {
      let status: Int32
      do {
        status = try await process.wait(timeoutInSeconds: 12).exitCode
      } catch {
        let failures = await discard()
        throw Failure.check("\(error) cleanup=\(failures)")
      }
      try await process.delete()
      guard status == 0, !output.overflowed else {
        throw Failure.check("SQL " + output.text)
      }
      return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  static func sql(
    _ container: LinuxContainer, id: String = UUID().uuidString,
    query: String, queryID: String? = nil
  ) async throws -> String {
    let execution = try await startSQL(container, id: id, query: query, queryID: queryID)
    return try await execution.finish()
  }

  static func startSQL(
    _ container: LinuxContainer, id: String = UUID().uuidString,
    query: String, queryID: String? = nil, nativeProbe: String? = nil
  ) async throws -> RunningSQL {
    let output = BoundedOutput()
    let process = try await container.exec(id) { config in
      config.arguments = [
        "/usr/bin/clickhouse", "client", "--host=127.0.0.1", "--port=9000",
        "--format=TSVRaw", "--receive_timeout=10", "--send_timeout=3", "--connect_timeout=2",
        "--max_threads=1", "--max_memory_usage=201326592", "--max_execution_time=8",
        "--timeout_before_checking_execution_speed=0", "--max_rows_to_read=500000",
        "--max_bytes_to_read=100663296", "--max_result_rows=1000",
      ]
      if let nativeProbe {
        config.arguments = [nativeProbe, "--http-query", query]
        if let queryID { config.arguments.append(queryID) }
      } else {
        if let queryID { config.arguments += ["--query_id", queryID] }
        config.arguments += ["--query", query]
      }
      config.stdout = output
      config.stderr = output
      config.noNewPrivileges = true
    }
    let execution = RunningSQL(process: process, output: output)
    do {
      try await process.start()
      guard process.pid > 0 else { throw Failure.check("SQL process did not start") }
    } catch {
      let failures = await execution.discard()
      throw Failure.check("\(error) cleanup=\(failures)")
    }
    return execution
  }
  static func waitMemory(
    _ vm: NativeVirtualMachine, bytes: UInt64,
    deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(8))
  ) async throws {
    while vm.pluggedBytes != bytes {
      guard ContinuousClock.now < deadline else { throw Failure.check("memory convergence") }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
  static func workload(
    container: LinuxContainer, vm: NativeVirtualMachine, output: URL,
    probe: URL, mode: String
  ) async throws -> Bool {
    let geometry = vm.memoryGeometry
    let entropyPressure = mode == "autonomous-entropy-balloon"
    let pressureRelation = entropyPressure ? "pressure_entropy_lab" : "pressure_lab"
    let pressureColumns = "id UInt64, payload String"
    let pressureRows = 557056
    let pressureWidth = 4096
    let autonomousFault = [
      "autonomous-stop-balloon", "autonomous-cancel-balloon", "autonomous-disconnect-balloon",
    ].contains(mode)
    let autonomousBalloon = mode == "autonomous-pressure-balloon" || entropyPressure || autonomousFault
    let classicPressure = mode == "pressure-balloon" || autonomousBalloon
    let classic = ["memory-balloon", "memory-balloon-wide", "pressure-balloon",
      "autonomous-pressure-balloon", "autonomous-entropy-balloon",
      "autonomous-stop-balloon", "autonomous-cancel-balloon", "autonomous-disconnect-balloon",
    ].contains(mode)
    let pulseBytes: UInt64 = (classicPressure ? 2048 : mode == "memory-balloon-wide" ? 768 : 128)
      << 20
    let reporting = [
      "continuous-pressure-reporting", "continuous-pressure-reporting-small-boot",
    ].contains(mode)
    let protectedCapacity = mode == "continuous-pressure-protected" || reporting || classicPressure
    let pressureWide = mode == "continuous-pressure-wide" || protectedCapacity
    let memoryLimit: UInt64 = (pressureWide ? 2816 : 896) << 20
    var commands: [[String: String]] = []
    var observations: [[String: Any]] = []
    var resources: [[String: Any]] = []
    var memoryDiagnostics: [[String: String]] = []
    var policySamples: [[String: Any]] = []
    var policyRequests: [[String: UInt64]] = []
    let adaptive = ["adaptive", "adaptive-busy"].contains(mode)
    let continuous = [
      "continuous", "continuous-cancel", "continuous-cancel-release", "continuous-soak",
      "continuous-stop", "continuous-churn",
      "continuous-expire", "continuous-expired-stop", "continuous-unsettled",
      "continuous-sustained", "continuous-uart", "continuous-pressure-wide",
      "continuous-pressure-protected",
      "continuous-pressure-reporting",
      "continuous-pressure-reporting-small-boot",
    ].contains(mode)
    var churn: [[String: UInt64]] = []
    var expectedGracefulStop = false
    var expectedLifetimeExpiry = false
    var observer: NativeMemoryGovernor?
    var observerTask: Task<Void, Error>?
    var balloonObserver: NativeBalloonGovernor?
    var balloonTask: Task<Void, Error>?
    var expectedCancellation = false
    var expectedDisconnection = false
    let began = ContinuousClock.now
    func now() -> UInt64 {
      let elapsed = began.duration(to: .now).components
      return UInt64(elapsed.seconds) * 1_000_000_000 + UInt64(elapsed.attoseconds / 1_000_000_000)
    }
    guard
      let budget = BalloonBudget(
        installedBytes: geometry.maximumBytes, minimumResidentBytes: geometry.bootBytes,
        granuleBytes: 2 << 20, maximumStepBytes: min(128 << 20, geometry.dynamicBytes)),
      var governor = BalloonController(
        budget: budget, epoch: 1, guestReserveBytes: 512 << 20, hysteresisBytes: 32 << 20,
        maximumObservationAgeNanoseconds: 3_000_000_000, cooldownNanoseconds: 300_000_000,
        completionTimeoutNanoseconds: 8_000_000_000)
    else { throw Failure.check("policy geometry") }
    defer { governor.retire() }
    let input = NativeMemoryInput()
    let canaryOutput = NativeMemoryOutput()
    let session = MemoryProbeSession(
      input: input, output: canaryOutput, cpus: vm.processorCount)
    var canary: LinuxProcess?
    var memoryMonitor: LinuxProcess?
    var memorySession: NativeMemorySession?
    var activeLoad: Task<String, Error>?
    var primary = ""
    var cleanup: [String] = []
    // writeFile(create:) does not truncate; a recovered filesystem can contain an older probe.
    let guestProbe = "/lab/canary-" + UUID().uuidString.lowercased()
    func sql(
      _ container: LinuxContainer, id: String = UUID().uuidString,
      query: String, queryID: String? = nil
    ) async throws -> String {
      let execution = try await Lab.startSQL(
        container, id: id, query: query, queryID: queryID, nativeProbe: classic ? guestProbe : nil)
      return try await execution.finish()
    }
    do {
      let agent = try await vm.dialAgent()
      do {
        let written = try await uploadProbe(
          probe, path: "/run/container/swiftos-native/rootfs" + guestProbe, agent: agent)
        guard written > 0 else { throw Failure.check("probe empty") }
        let metadata = try await agent.stat(
          root: "/run/container/swiftos-native/rootfs", path: guestProbe)
        commands.append([
          "probePath": guestProbe, "probeWrittenBytes": String(written),
          "probeGuestBytes": String(metadata.size),
        ])
        guard metadata.size == written, metadata.uid == 0, metadata.nlink == 1,
          metadata.mode & 0o170000 == 0o100000
        else { throw Failure.check("probe guest geometry") }
        try await agent.close()
      } catch {
        try? await agent.close()
        throw error
      }
      var ready = false
      for attempt in 0..<20 {
        do { ready = try await sql(container, query: "SELECT 1 LIMIT 1") == "1" } catch {
          commands.append(["readinessFailure": "\(attempt) \(error)"])
        }
        if ready { break }
        try await Task.sleep(for: .milliseconds(100))
      }
      guard ready else { throw Failure.check("server readiness") }
      if classic {
        var refused = false
        do { _ = try await sql(container, query: "SELECT throwIf(1) LIMIT 1") } catch {
          guard String(describing: error).contains("loadResponse"),
            String(describing: error).contains("Code: 395.") else { throw error }
          refused = true
        }
        guard refused else { throw Failure.check("native HTTP accepted SQL exception") }
        commands.append(["nativeHTTPErrorControl": "refused", "sqlTransport": "native-swift-http"])
      }
      if pressureWide {
        let interval = try await sql(
          container,
          query:
            "SELECT value FROM system.server_settings WHERE name='cgroups_memory_usage_observer_wait_time' LIMIT 1"
        )
        guard interval == (protectedCapacity ? "15" : "1") else {
          throw Failure.check("memory observer interval " + interval)
        }
        commands.append([
          "applicationCapacityObserverSeconds": interval,
          "applicationCapacityCompatibility": protectedCapacity
            ? "protected-capacity-control" : "explicit-observer-cadence",
        ])
      }
      if mode != "recover" {
        _ = try await sql(
          container,
          query:
            "CREATE TABLE default.ram_lab (id UInt64, payload String) ENGINE=MergeTree ORDER BY id SETTINGS fsync_after_insert=1, fsync_part_directory=1"
        )
        for batch in 0..<4 {
          _ = try await sql(
            container,
            query:
              "INSERT INTO default.ram_lab SELECT number + \(batch * 100000), repeat(hex(cityHash64(number + \(batch * 100000))), 8) FROM numbers(100000)"
          )
        }
      }
      let integrity =
        "SELECT count(), sum(id), sum(cityHash64(payload)), sum(length(payload)) FROM default.ram_lab WHERE id < 400000 LIMIT 1"
      let expected = "400000\t79999800000\t9410121038903895322\t51176128"
      let baseline = try await sql(container, query: integrity)
      guard baseline == expected else { throw Failure.check("initial integrity " + baseline) }
      canary = try await container.exec("canary") { config in
        config.arguments = [guestProbe, String(vm.processorCount), String(vm.networkCount)]
        config.stdin = input
        config.stdout = canaryOutput
        config.stderr = canaryOutput
        config.noNewPrivileges = true
      }
      try await canary!.start()
      let initial = try await session.start()
      let initialMemory = initial.total
      guard initialMemory >= geometry.dynamicBytes, initialMemory <= geometry.maximumBytes else {
        throw Failure.check("initial guest geometry")
      }
      let bootGuestBytes = initialMemory - geometry.dynamicBytes
      let engine = try await sql(
        container,
        query:
          "SELECT engine_full FROM system.tables WHERE database='default' AND name='ram_lab' LIMIT 1"
      )
      guard engine.contains("fsync_after_insert = 1"), engine.contains("fsync_part_directory = 1")
      else { throw Failure.check("durability settings") }
      commands.append(["effectiveEngine": engine])
      var sequence = 0
      var guestCapacity = initialMemory
      var available: UInt64 = 0
      var capturedAt: UInt64 = 0
      func verify(
        _ command: String = "VERIFY", quit: Bool = false,
        deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(5))
      ) async throws -> UInt64 {
        let beganCommand = now()
        defer {
          commands.append([
            "probeCommand": quit ? "QUIT" : command,
            "elapsedNanoseconds": String(now() - beganCommand),
          ])
        }
        let reply = try await session.observe(quit ? "QUIT" : command, deadline: deadline)
        guard reply.total >= bootGuestBytes, reply.total <= initialMemory else {
          throw Failure.check("guest geometry")
        }
        guestCapacity = reply.total
        sequence = Int(reply.sequence)
        guard reply.capturedAt >= began else { throw Failure.check("observation clock") }
        let capture = began.duration(to: reply.capturedAt).components
        capturedAt =
          UInt64(capture.seconds) * 1_000_000_000
          + UInt64(capture.attoseconds / 1_000_000_000)
        available = reply.available
        return reply.total
      }
      func control() throws {
        try Task.checkCancellation()
        let returnedAt = now()
        try governor.checkDeadline(nowNanoseconds: returnedAt)
        var pressure: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0) == 0,
          size == MemoryLayout<Int32>.size, [1, 2].contains(pressure)
        else { throw Failure.check("host memory pressure or unavailable native observation") }
        let state = vm.memoryState
        guard returnedAt >= capturedAt, returnedAt - capturedAt <= 3_000_000_000 else {
          throw Failure.check("stale guest observation")
        }
        if guestCapacity != bootGuestBytes + state.pluggedBytes, governor.pendingRequest == nil,
          available >= 512 << 20
        {
          return
        }
        let sample = BalloonController.Observation(
          epoch: 1, sequence: UInt64(sequence), capturedAtNanoseconds: capturedAt,
          actualResidentBytes: geometry.bootBytes + state.pluggedBytes,
          requestedResidentBytes: geometry.bootBytes + state.requestedBytes,
          guestAvailableBytes: available, hostResidentLimitBytes: geometry.maximumBytes,
          hostUnderPressure: pressure != 1, guestUnderPressure: false)
        let request = try governor.observe(sample, nowNanoseconds: returnedAt)
        if let request {
          try vm.requestMemory(bytes: request.targetResidentBytes - geometry.bootBytes)
          let deliveredAt = now()
          try governor.didApply(
            request, afterObservationSequence: UInt64(sequence), atNanoseconds: deliveredAt)
          policyRequests.append([
            "initialBytes": request.initialResidentBytes,
            "targetBytes": request.targetResidentBytes,
            "sequence": request.sequence, "issuedAt": request.issuedAtNanoseconds,
            "deliveredAt": deliveredAt,
          ])
        }
        policySamples.append([
          "sequence": sequence, "capturedAt": capturedAt, "returnedAt": returnedAt,
          "guestAvailableBytes": available, "pluggedBytes": state.pluggedBytes,
          "requestedBytes": state.requestedBytes, "hostPressure": pressure,
          "pending": governor.pendingRequest != nil,
        ])
        guard policySamples.count <= 48 else { throw Failure.check("policy sample bound") }
      }
      func settle(_ bytes: UInt64) async throws -> UInt64 {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        repeat {
          try governor.checkDeadline(nowNanoseconds: now())
          guard ContinuousClock.now < deadline else { throw Failure.check("policy convergence") }
          let total = try await verify(deadline: min(deadline, .now.advanced(by: .seconds(5))))
          try control()
          if vm.pluggedBytes == bytes, governor.pendingRequest == nil,
            total == bootGuestBytes + bytes
          {
            return total
          }
          try await Task.sleep(for: .milliseconds(200))
        } while true
      }
      func waitGuestMemory(
        _ expected: UInt64, deadline: ContinuousClock.Instant
      ) async throws -> UInt64 {
        while ContinuousClock.now < deadline {
          let total = try await verify(deadline: min(deadline, .now.advanced(by: .seconds(5))))
          if total == expected { return total }
          try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure.check("guest memory-online convergence")
      }
      func loadState(cycle: Int) async throws -> (Int, UInt64) {
        let reply = try await session.load(cycle: cycle)
        sequence = Int(reply.sequence)
        return (reply.count, reply.bytes)
      }
      func waitObserver(
        _ bytes: UInt64?, deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(8))
      ) async throws {
        guard let observer else { throw Failure.check("observer missing") }
        repeat {
          try Task.checkCancellation()
          let status = observer.status
          guard status.failure.isEmpty else { throw Failure.check("observer " + status.failure) }
          if status.running, status.sampleCount > 0, !status.pending, status.capacityReady,
            bytes.map({ vm.pluggedBytes == $0 }) ?? (vm.pluggedBytes > 0)
          {
            return
          }
          guard ContinuousClock.now < deadline else { throw Failure.check("observer convergence") }
          try await Task.sleep(for: .milliseconds(20))
        } while true
      }
      func resourceSnapshot(_ phase: String) async throws {
        let agent = try await vm.dialAgent()
        do {
          let values = try await agent.containerStatistics(
            containerIDs: ["swiftos-native"],
            categories: [.memory, .memoryEvents, .cpu])
          try await agent.close()
          guard values.count == 1, let memory = values[0].memory,
            let events = values[0].memoryEvents
          else { throw Failure.check("cgroup statistics missing") }
          let host = try ProcessMemorySnapshot.capture()
          var usage = rusage()
          guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw Failure.check("host rusage") }
          resources.append([
            "hostCapturedAtNanoseconds": now(), "hostResidentBytes": host.residentBytes,
            "hostPhysicalFootprintBytes": host.physicalFootprintBytes.map { $0 as Any } ?? NSNull(),
            "hostUserMicroseconds": usage.ru_utime.tv_sec * 1_000_000 + Int(usage.ru_utime.tv_usec),
            "hostSystemMicroseconds": usage.ru_stime.tv_sec * 1_000_000
              + Int(usage.ru_stime.tv_usec),
            "phase": phase, "usageBytes": memory.usageBytes,
            "limitBytes": memory.limitBytes, "swapBytes": memory.swapUsageBytes,
            "cacheBytes": memory.cacheBytes, "anonBytes": memory.anon,
            "oom": events.oom, "oomKill": events.oomKill, "maxEvents": events.max,
            "highEvents": events.high, "cpuUsageUsec": values[0].cpu?.usageUsec ?? 0,
          ])
          // memory.max events include successful file-cache reclaim, not only OOM failures.
          guard events.oom == 0, events.oomKill == 0,
            memory.limitBytes == memoryLimit, memory.usageBytes <= memory.limitBytes
          else { throw Failure.check("cgroup limits/OOM \(resources.last!)") }
        } catch {
          try? await agent.close()
          throw error
        }
      }
      try await waitMemory(vm, bytes: geometry.dynamicBytes)
      try await resourceSnapshot("baseline")
      if autonomousBalloon {
        let monitorInput = NativeMemoryInput()
        let monitorOutput = NativeMemoryOutput()
        let telemetry = NativeMemorySession(input: monitorInput, output: monitorOutput)
        memorySession = telemetry
        memoryMonitor = try await container.exec("memory-monitor") { config in
          config.arguments = [guestProbe, "--memory-monitor"]
          config.stdin = monitorInput
          config.stdout = monitorOutput
          config.stderr = monitorOutput
          config.noNewPrivileges = true
        }
        try await memoryMonitor!.start()
        try await telemetry.start()
        let driver = try NativeBalloonGovernor(
          probe: telemetry, vm: vm, residentTarget: 1024 << 20)
        balloonObserver = driver
        balloonTask = Task { try await driver.run() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while driver.snapshot.samples.totalCount == 0 {
          guard driver.snapshot.failureError == nil, ContinuousClock.now < deadline else {
            throw Failure.check("autonomous balloon owner admission")
          }
          try await Task.sleep(for: .milliseconds(5))
        }
        do {
          try vm.requestBalloon(bytes: 0)
          throw Failure.check("manual setter bypassed balloon owner")
        } catch NativeControlFailure.ownership {}
        commands.append(["autonomousBalloonExclusiveOwner": "verified"])
      }
      if continuous {
        let monitorInput = NativeMemoryInput()
        let monitorOutput = NativeMemoryOutput()
        let telemetry = NativeMemorySession(
          input: monitorInput, output: monitorOutput)
        memorySession = telemetry
        memoryMonitor = try await container.exec("memory-monitor") { config in
          config.arguments = [guestProbe, "--memory-monitor"]
          config.stdin = monitorInput
          config.stdout = monitorOutput
          config.stderr = monitorOutput
          config.noNewPrivileges = true
        }
        try await memoryMonitor!.start()
        try await telemetry.start()
        if mode == "continuous-unsettled" {
          try vm.requestMemory(bytes: 0)
          let premature = NativeMemoryGovernor(
            probe: telemetry, vm: vm, began: began, bootGuestBytes: bootGuestBytes)
          do {
            try await premature.run()
            throw Failure.check("unsettled device admitted a controller")
          } catch NativeControlFailure.unsettled {}
          let refused = vm.memoryControlStatus
          guard refused.generation == 0, !refused.retired, !refused.quarantined else {
            throw Failure.check("retryable refusal consumed memory authority")
          }
          try vm.releaseDiagnosticAlias()
          try await waitMemory(vm, bytes: 0)
          _ = try await waitGuestMemory(bootGuestBytes, deadline: .now.advanced(by: .seconds(8)))
          let belowFloor = NativeMemoryGovernor(
            probe: telemetry, vm: vm, began: began, bootGuestBytes: bootGuestBytes)
          var floorError: NativeControlFailure?
          do { try await belowFloor.run() } catch let error as NativeControlFailure {
            floorError = error
          }
          let floorRefusal = vm.memoryControlStatus
          commands.append([
            "defaultFloorEntryFailure": floorError.map { String(describing: $0) } ?? "",
            "defaultFloorEntryGeneration": String(floorRefusal.generation),
            "defaultFloorEntryRetired": String(floorRefusal.retired),
          ])
          guard floorError == .belowResidentFloor, floorRefusal.generation == 0,
            !floorRefusal.retired, !floorRefusal.quarantined
          else { throw Failure.check("resident floor refusal consumed memory authority") }
          try vm.requestMemory(bytes: geometry.dynamicBytes)
          try await waitMemory(vm, bytes: geometry.dynamicBytes)
          _ = try await waitGuestMemory(initialMemory, deadline: .now.advanced(by: .seconds(8)))
          try vm.releaseDiagnosticAlias()
        }
        if mode == "continuous" {
          let cancelled = NativeMemoryGovernor(
            probe: telemetry, vm: vm, began: began, bootGuestBytes: bootGuestBytes)
          let gate = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
          let task = Task {
            var events = gate.stream.makeAsyncIterator()
            _ = await events.next()
            try await cancelled.run()
          }
          task.cancel()
          switch await task.result {
          case .success: throw Failure.check("pre-cancelled governor was admitted")
          case .failure(let error):
            guard error is CancellationError else { throw error }
          }
          gate.continuation.finish()
          let admission = vm.memoryControlStatus
          guard !cancelled.snapshot.claimed, admission.generation == 0, !admission.retired else {
            throw Failure.check("pre-cancelled entry retired healthy authority")
          }
          commands.append(["preCancelledControlAdmission": "refused"])
        }
        let driver = NativeMemoryGovernor(
          probe: telemetry, vm: vm, began: began, bootGuestBytes: bootGuestBytes,
          minimumResidentBytes: protectedCapacity ? nil : geometry.bootBytes,
          lifetimeDeadline: mode == "continuous-expired-stop"
            ? .now.advanced(by: .seconds(-1))
            : mode == "continuous-expire"
              ? .now.advanced(by: .seconds(2))
              : mode == "continuous-sustained" ? nil : began.advanced(by: .seconds(180)),
          samplingInterval: mode == "continuous-soak" ? .milliseconds(100) : .milliseconds(200))
        observer = driver
        if ["continuous-expired-stop", "continuous-unsettled"].contains(mode) {
          driver.requestStop()
        }
        observerTask = Task { try await driver.run() }
        if mode == "continuous" {
          let deadline = ContinuousClock.now.advanced(by: .seconds(3))
          while driver.status.sampleCount == 0 {
            guard ContinuousClock.now < deadline, driver.status.failure.isEmpty else {
              throw Failure.check("exclusive owner not observed")
            }
            try await Task.sleep(for: .milliseconds(5))
          }
          do {
            try vm.requestMemory(bytes: 0)
            throw Failure.check("manual setter bypassed active governor")
          } catch NativeControlFailure.ownership {}
          let competitor = NativeMemoryGovernor(
            probe: telemetry, vm: vm, began: began, bootGuestBytes: bootGuestBytes)
          do {
            try await competitor.run()
            throw Failure.check("second governor bypassed memory authority")
          } catch NativeControlFailure.ownership {}
          guard !competitor.status.running,
            competitor.snapshot.failureError as? NativeControlFailure == .ownership
          else { throw Failure.check("competing owner final state") }
          commands.append(["exclusiveControllerOwnership": "verified"])
        }
        if mode == "continuous-unsettled" {
          try await observerTask!.value
          observerTask = nil
          let admitted = vm.memoryControlStatus
          let durable = try await sql(container, query: integrity)
          guard admitted.generation == 1, !admitted.retired, !admitted.quarantined,
            !driver.status.running, driver.snapshot.requestHistory.totalCount == 0,
            durable == expected
          else { throw Failure.check("settled controller retry failed") }
          expectedGracefulStop = true
          commands.append([
            "unsettledAdmission": "refused", "retryGeneration": "1", "integrity": durable,
          ])
          try await resourceSnapshot("unsettled-admission-retried")
        } else if mode == "continuous-expired-stop" {
          switch await observerTask!.result {
          case .success: throw Failure.check("observer ignored expired lifetime with late stop")
          case .failure(let error):
            guard error as? NativeControlFailure == .lifetimeExpired else { throw error }
          }
          observerTask = nil
          let expired = driver.snapshot
          let integrityAfterExpiry = try await sql(container, query: integrity)
          guard !expired.running, !expired.pending, expired.sampleHistory.totalCount == 0,
            expired.requestHistory.totalCount == 0,
            expired.failureError as? NativeControlFailure == .lifetimeExpired,
            integrityAfterExpiry == expected
          else { throw Failure.check("late stop concealed lifetime expiry") }
          do {
            try vm.requestMemory(bytes: geometry.dynamicBytes)
            throw Failure.check("expired authority admitted a manual setter")
          } catch NativeControlFailure.ownership {}
          expectedLifetimeExpiry = true
          commands.append([
            "lateStopPreservesLifetimeFailure": "verified", "integrity": integrityAfterExpiry,
          ])
          try await resourceSnapshot("late-stop-lifetime-expired")
        } else if mode == "continuous-expire" {
          switch await observerTask!.result {
          case .success: throw Failure.check("observer ignored lifetime deadline")
          case .failure(let error):
            guard error as? NativeControlFailure == .lifetimeExpired else { throw error }
          }
          observerTask = nil
          let expired = driver.snapshot
          guard !expired.running, !expired.pending, expired.capacityReady,
            expired.requestHistory.totalCount == 0,
            try await sql(container, query: integrity) == expected
          else { throw Failure.check("deadline admission/status/integrity") }
          expectedLifetimeExpiry = true
          try await resourceSnapshot("lifetime-expired-without-new-admission")
        } else if ["continuous-cancel", "continuous-cancel-release", "continuous-stop"].contains(
          mode)
        {
          let deadline = ContinuousClock.now.advanced(by: .seconds(8))
          while vm.refusalCount == 0 || !driver.status.pending {
            guard ContinuousClock.now < deadline, driver.status.failure.isEmpty else {
              throw Failure.check("cancel point not reached")
            }
            try await Task.sleep(for: .milliseconds(10))
          }
          if mode == "continuous-stop" {
            driver.requestStop()
            try vm.releaseDiagnosticAlias()
            try await observerTask!.value
            observerTask = nil
            let stopped = driver.snapshot
            guard !stopped.running, !stopped.pending, stopped.capacityReady,
              stopped.failure.isEmpty, stopped.requestHistory.totalCount == 1,
              try await sql(container, query: integrity) == expected
            else { throw Failure.check("graceful pending drain/status/integrity") }
            expectedGracefulStop = true
            try await resourceSnapshot("gracefully-stopped-pending")
          } else {
            observerTask!.cancel()
            switch await observerTask!.result {
            case .success: throw Failure.check("observer ignored cancellation")
            case .failure(let error):
              guard error is CancellationError else { throw error }
            }
            observerTask = nil
            expectedCancellation = true
            guard !driver.status.running, try await sql(container, query: integrity) == expected
            else {
              throw Failure.check("cancel retirement/integrity")
            }
            if mode == "continuous-cancel-release" {
              // A fresh round trip requires coordinator progress after authority retirement.
              _ = try await verify()
              let retained = vm.pluggedBytes
              try vm.releaseDiagnosticAlias()
              let until = ContinuousClock.now.advanced(by: .seconds(2))
              repeat {
                _ = try await verify()
                guard vm.pluggedBytes == retained else {
                  throw Failure.check("retired memory control continued shrinking")
                }
                try await Task.sleep(for: .milliseconds(50))
              } while ContinuousClock.now < until
              commands.append(["retiredControlPreservesBacking": "verified"])
            }
            try await resourceSnapshot("cancelled-pending")
          }
        } else {
          try await waitObserver(
            protectedCapacity ? geometry.dynamicBytes : 0,
            deadline: .now.advanced(by: .seconds(pressureWide ? 30 : 8)))
        }
      }
      if expectedCancellation || expectedLifetimeExpiry {
        try await vm.waitForMemoryControlRetirement(deadline: .now.advanced(by: .seconds(1)))
        let retirement = vm.memoryControlStatus
        guard retirement.retired, retirement.quarantined else {
          throw Failure.check("native memory quarantine not acknowledged")
        }
        commands.append(["nativeMemoryQuarantine": "acknowledged"])
      }
      if vm.aliasDiagnosticEnabled, !adaptive, !continuous {
        try vm.requestMemory(bytes: 0)
        let refusalDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while vm.refusalCount == 0 {
          guard ContinuousClock.now < refusalDeadline else {
            throw Failure.check("BUSY not observed")
          }
          try await Task.sleep(for: .milliseconds(5))
        }
        _ = try await verify()
        guard try await sql(container, query: integrity) == expected else {
          throw Failure.check("BUSY data")
        }
        // Validate the refusal separately so its full integrity scan cannot consume the load window.
        try vm.requestMemory(bytes: geometry.dynamicBytes)
      }
      if mode == "continuous-uart" {
        let agent = try await vm.dialAgent()
        do {
          for index in 0..<64 {
            let text =
              "<4>SWIFTOS_UART_BURST_\(index) " + String(repeating: "x", count: 384) + "\n"
            let issuedAt = now()
            try await agent.writeFile(
              path: "/dev/kmsg", data: Data(text.utf8), flags: .init(create: false), mode: 0)
            commands.append([
              "uartBurst": String(index), "uartWriteNanoseconds": String(now() - issuedAt),
            ])
            guard observer?.status.failure.isEmpty == true else {
              throw Failure.check("UART stalled observer")
            }
          }
          try await agent.close()
          try await waitObserver(0)
        } catch {
          try? await agent.close()
          throw error
        }
      }
      func balloonPulse(cycle: Int, minimumResidentReturn: UInt64 = 0) async throws
        -> [String: UInt64]
      {
        let releasedAt = now()
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        let before = vm.backingRecyclingStatus.coldResidentBytes
        let totalBefore = try await verify("OBS_REFRESH")
        let availableBefore = available
        guard totalBefore == initialMemory, availableBefore >= pulseBytes + (512 << 20) else {
          throw Failure.check("balloon guest reserve/capacity")
        }
        let issuedAt = now()
        try vm.requestBalloon(bytes: pulseBytes)
        while true {
          let state = vm.balloonState
          guard ContinuousClock.now < deadline, !state.quarantined else {
            throw Failure.check("balloon inflate deadline/quarantine")
          }
          if minimumResidentReturn > 0 {
            if vm.backingRecyclingStatus.coldResidentBytes - before >= minimumResidentReturn { break }
          } else if state.settled, state.targetBytes == pulseBytes,
            state.actualBytes == state.ownedBytes, state.ownedBytes == pulseBytes
          { break }
          try await Task.sleep(for: .milliseconds(5))
        }
        let inflatedAt = now()
        let ownedAtGoal = vm.balloonState.ownedBytes
        let heldTotal = try await verify("OBS_REFRESH")
        let heldAvailable = available
        guard heldTotal == initialMemory, ContinuousClock.now < deadline,
          vm.balloonState.targetBytes == pulseBytes
        else { throw Failure.check("balloon held capacity/lease") }
        if minimumResidentReturn == 0 {
          guard availableBefore >= heldAvailable,
            ((pulseBytes - (64 << 20))...(pulseBytes + (64 << 20)))
              .contains(availableBefore - heldAvailable)
          else {
            commands.append([
              "balloonAccountingCycle": String(cycle),
              "availableBefore": String(availableBefore), "availableHeld": String(heldAvailable),
            ])
            throw Failure.check("balloon synchronized MemAvailable accounting")
          }
        }
        let during = try await loadState(cycle: cycle)
        guard during.0 == 1, during.1 >= 16 << 20 else {
          throw Failure.check("SQL not live during classic balloon")
        }
        try vm.requestBalloon(bytes: 0)
        let rescueDeadline = ContinuousClock.now.advanced(by: .seconds(8))
        while true {
          let state = vm.balloonState
          guard ContinuousClock.now < rescueDeadline, !state.quarantined else {
            throw Failure.check("balloon deflate deadline/quarantine")
          }
          if state.settled, state.targetBytes == 0, state.actualBytes == 0, state.ownedBytes == 0 {
            break
          }
          try await Task.sleep(for: .milliseconds(5))
        }
        let deflatedAt = now()
        let restored = try await verify()
        guard restored == initialMemory else { throw Failure.check("balloon restore capacity") }
        return [
          "initialGuestBytes": initialMemory, "heldGuestBytes": heldTotal,
          "restoredGuestBytes": restored, "balloonOwnedBytes": ownedAtGoal,
          "requestedBalloonBytes": pulseBytes,
          "availableBefore": availableBefore, "availableHeld": heldAvailable,
          "releasedAtNanoseconds": releasedAt, "issuedAtNanoseconds": issuedAt,
          "inflatedAtNanoseconds": inflatedAt, "deflatedAtNanoseconds": deflatedAt,
          "reportedResidentBytesRecycled": vm.backingRecyclingStatus.coldResidentBytes - before,
          "activeDuringBalloonMemoryBytes": during.1,
        ]
      }
      for cycle
        in (expectedCancellation || expectedGracefulStop || expectedLifetimeExpiry ? [] : [1, 2])
      {
        if classic {
          if !classicPressure {
            _ = try await verify("HOLD")
            _ = try await verify("DROP")
          }
          do {
            try vm.requestMemory(bytes: 0)
            throw Failure.check("competing virtio-mem setter admitted during balloon mode")
          } catch NativeControlFailure.ownership {}
        }
        if mode == "memory-reporting" {
          let deadline = ContinuousClock.now.advanced(by: .seconds(8))
          while vm.backingRecyclingStatus.bytes == 0 {
            guard ContinuousClock.now < deadline else {
              throw Failure.check("reporting did not precede unplug control")
            }
            try await Task.sleep(for: .milliseconds(20))
          }
        }
        var pressurePeakGuest: UInt64 = 0
        var pressurePeakBacking: UInt64 = 0
        var peakRecycledResidentBytes: UInt64 = 0
        if pressureWide {
          // Sixteen 128 MiB policy steps need their own aggregate phase fence;
          // the governor's wire/completion/drain fences remain unchanged.
          if !classicPressure {
            try await waitObserver(
              protectedCapacity ? geometry.dynamicBytes : 0,
              deadline: .now.advanced(by: .seconds(30)))
          }
          _ = try await sql(
            container,
            query:
              "CREATE TABLE IF NOT EXISTS default.\(pressureRelation) (\(pressureColumns)) ENGINE=Memory SETTINGS compress=0"
          )
          // Preserve the compressible control; random bytes separately test resident RAM return.
          let batchRows = 32768
          // Leave room for SIMD padding without doubling the random column's reserved capacity.
          let blockRows = entropyPressure ? 2047 : 2048
          for index in 0..<(pressureRows / batchRows) {
            let offset = index * batchRows
            let payload = entropyPressure
              ? "number + \(offset), randomString(4096, number)"
              : "number + \(offset), repeat(hex(cityHash64(number + \(offset))), 256)"
            _ = try await sql(
              container,
              query:
                "INSERT INTO default.\(pressureRelation) SELECT \(payload) FROM numbers(\(batchRows)) SETTINGS max_block_size=\(blockRows)"
            )
            if index % 4 == 0 {
              guard try await sql(container, query: integrity) == expected else {
                throw Failure.check("integrity during pressure ramp")
              }
            }
            commands.append([
              "pressureCycle": String(cycle), "pressureBatches": String(index + 1),
              "heldPressureBytes": String((index + 1) * batchRows * pressureWidth),
              "pluggedBytes": String(vm.pluggedBytes), "capturedAt": String(now()),
            ])
            // Backpressure the workload on fresh guest headroom, not on a fixed success delay.
            if classicPressure {
              let total = try await verify("OBS")
              guard total == initialMemory, vm.pluggedBytes == geometry.dynamicBytes else {
                throw Failure.check("classic pressure ramp capacity")
              }
            } else {
              let firstSequence = observer!.snapshot.sampleHistory.totalCount
              let headroomDeadline = ContinuousClock.now.advanced(by: .seconds(8))
              while true {
                let sample = observer!.snapshot
                guard sample.failure.isEmpty, ContinuousClock.now < headroomDeadline else {
                  throw Failure.check("pressure ramp headroom")
                }
                if sample.sampleHistory.totalCount >= firstSequence + 2, !sample.pending,
                  sample.capacityReady,
                  sample.samples.last?["guestAvailableBytes"].map({ $0 >= 480 << 20 }) == true
                    || vm.pluggedBytes == geometry.dynamicBytes
                {
                  break
                }
                try await Task.sleep(for: .milliseconds(200))
              }
            }
          }
          let pressureTable = try await sql(
            container,
            query:
              "SELECT total_rows, total_bytes FROM system.tables WHERE database='default' AND name='\(pressureRelation)' LIMIT 1"
          )
          let pressureFields = pressureTable.split(separator: "\t")
          guard pressureFields.count == 2, UInt64(pressureFields[0]) == UInt64(pressureRows),
            let allocated = UInt64(pressureFields[1]), allocated >= 2176 << 20
          else { throw Failure.check("pressure table accounting \(pressureTable)") }
          commands.append([
            "pressureTableRows": String(pressureRows), "pressureTableAllocatedBytes": String(allocated),
          ])
          if !classicPressure {
            try await waitObserver(
              geometry.dynamicBytes, deadline: .now.advanced(by: .seconds(30)))
          }
          pressurePeakGuest = try await verify("OBS")
          guard pressurePeakGuest == initialMemory else { throw Failure.check("pressure growth") }
          pressurePeakBacking = vm.memoryControlStatus.backingRetiredBytes
          peakRecycledResidentBytes = vm.backingRecyclingStatus.coldResidentBytes
          if reporting {
            commands.append([
              "reportingPeakRecycledResidentBytes": String(peakRecycledResidentBytes),
              "capturedAt": String(now()),
            ])
          }
          try await resourceSnapshot("pressure-peak-\(cycle)")
        }
        let queryID = "swiftos-load-\(cycle)"
        let query =
          "SELECT sum(n.number + sleepEachRow(0.00004)) FROM numbers(100000) AS n INNER JOIN (SELECT id, payload FROM default.ram_lab WHERE id < 100000) AS r ON n.number = r.id AND repeat(hex(cityHash64(n.number)), 8) = r.payload LIMIT 1 SETTINGS join_algorithm='hash'"
        let execution = try await startSQL(
          container, query: query, queryID: queryID, nativeProbe: classic ? guestProbe : nil)
        commands.append([
          "cycle": String(cycle), "loadProcessPID": String(execution.process.pid),
          "loadStartReturnedAt": String(now()),
        ])
        activeLoad = Task { try await execution.finish() }
        var observed: UInt64 = 0
        for _ in 0..<24 {
          let state = try await loadState(cycle: cycle)
          if state.0 == 1, state.1 >= 16 << 20 {
            observed = state.1
            break
          }
          try await Task.sleep(for: .milliseconds(25))
        }
        guard observed >= 16 << 20 else { throw Failure.check("active query not observed") }
        if classic && !classicPressure {
          let pulse = try await balloonPulse(cycle: cycle)
          let aggregate = try await activeLoad!.value
          activeLoad = nil
          guard aggregate == "4999950000", vm.memoryControlStatus.backingRetiredBytes == 0,
            try await sql(container, query: integrity) == expected
          else { throw Failure.check("balloon restore/integrity") }
          try await resourceSnapshot("balloon-restored-\(cycle)")
          var record: [String: Any] = pulse.mapValues { $0 as Any }
          record["cycle"] = cycle
          record["integrity"] = expected
          record["loadResult"] = aggregate
          observations.append(record)
          continue
        }
        if pressureWide {
          let releaseStarted = now()
          _ = try await sql(container, query: "TRUNCATE TABLE default.\(pressureRelation)")
          // This releases the workload's allocator pages; VM capacity changes remain autonomous.
          _ = try await sql(container, query: "SYSTEM JEMALLOC PURGE")
          if protectedCapacity {
            if classicPressure {
              let pulse: [String: UInt64]
              if autonomousBalloon {
                if autonomousFault {
                  guard let driver = balloonObserver, let task = balloonTask else {
                    throw Failure.check("missing autonomous fault owner")
                  }
                  let admission = ContinuousClock.now.advanced(by: .seconds(3))
                  while true {
                    let candidate = vm.balloonState
                    guard driver.snapshot.running, driver.snapshot.failureError == nil,
                      driver.snapshot.stopRequestedAt == nil, ContinuousClock.now < admission else {
                      throw Failure.check("autonomous fault ownership point")
                    }
                    if candidate.ownedBytes >= 64 << 20, candidate.actualBytes >= 64 << 20,
                      candidate.targetBytes != 0 { break }
                    try await Task.sleep(for: .milliseconds(5))
                  }
                  guard try await verify() == initialMemory else {
                    throw Failure.check("pre-fault canary/capacity")
                  }
                  let preLoad = try await loadState(cycle: cycle)
                  let pre = vm.balloonState
                  guard preLoad.0 == 1, preLoad.1 >= 16 << 20,
                    pre.ownedBytes >= 64 << 20, pre.actualBytes >= 64 << 20,
                    pre.targetBytes != 0, driver.snapshot.running,
                    driver.snapshot.failureError == nil, driver.snapshot.stopRequestedAt == nil else {
                    throw Failure.check("pre-fault live load/ownership")
                  }
                  let owned = pre.ownedBytes
                  let faultBegan = ContinuousClock.now
                  switch mode {
                  case "autonomous-stop-balloon": driver.requestStop()
                  case "autonomous-cancel-balloon": task.cancel()
                  default:
                    await memorySession!.close()
                    expectedDisconnection = true
                  }
                  let deliveryBound: Duration = expectedDisconnection ? .seconds(3) : .milliseconds(100)
                  let deliveryDeadline = faultBegan.advanced(by: deliveryBound)
                  var nativeZero: NativeBalloonApplication?
                  while true {
                    if let generation = driver.snapshot.stopRequestGeneration,
                      let event = vm.lastBalloonApplication, event.generation == generation,
                      event.generation > pre.requestGeneration, event.epoch == pre.epoch,
                      event.targetBytes == 0 {
                      nativeZero = event
                      break
                    }
                    guard ContinuousClock.now < deliveryDeadline else {
                      throw Failure.check("autonomous stop native application")
                    }
                    try await Task.sleep(for: .milliseconds(1))
                  }
                  guard let nativeZero, nativeZero.appliedAt >= faultBegan,
                    nativeZero.previousTargetBytes != 0, nativeZero.previousOwnedBytes >= 64 << 20,
                    nativeZero.previousActualBytes >= 64 << 20,
                    faultBegan.duration(to: nativeZero.appliedAt) < deliveryBound else {
                    throw Failure.check("autonomous stop causal native application")
                  }
                  let zeroDelivery = faultBegan.duration(to: nativeZero.appliedAt)
                  let zeroLoad = try await loadState(cycle: cycle)
                  guard zeroLoad.0 == 1, zeroLoad.1 >= 16 << 20 else {
                    throw Failure.check("SQL not live at native zero application")
                  }
                  let outcome = await task.result
                  balloonTask = nil
                  let final = driver.snapshot
                  guard let stop = final.stopRequestedAt,
                    stop >= faultBegan, faultBegan.duration(to: stop) <= .seconds(3),
                    stop.duration(to: .now) < .seconds(8),
                    !final.running, !final.pending, final.cleanupError == nil,
                    vm.balloonState.settled, vm.balloonState.targetBytes == 0,
                    vm.balloonState.actualBytes == 0, vm.balloonState.ownedBytes == 0,
                    vm.balloonState.epoch == pre.epoch else {
                    throw Failure.check("autonomous fault drain")
                  }
                  let drainDuration = stop.duration(to: .now).components
                  let ownerGeneration = vm.memoryControlStatus.generation
                  let requestGeneration = vm.balloonState.requestGeneration
                  if mode == "autonomous-stop-balloon" {
                    try outcome.get()
                    guard final.failureError == nil, !vm.memoryControlStatus.retired else {
                      throw Failure.check("graceful stop retired healthy authority")
                    }
                    // Re-entry uses a new owner and remains observational at full soft capacity.
                    let replacement = try NativeBalloonGovernor(
                      probe: memorySession!, vm: vm, residentTarget: geometry.maximumBytes)
                    let resumed = Task { try await replacement.run() }
                    do {
                      let limit = ContinuousClock.now.advanced(by: .seconds(3))
                      while replacement.snapshot.samples.totalCount == 0 {
                        guard replacement.snapshot.failureError == nil, ContinuousClock.now < limit
                        else { throw Failure.check("healthy balloon re-admission") }
                        try await Task.sleep(for: .milliseconds(5))
                      }
                      guard replacement.snapshot.claimed, replacement.snapshot.running,
                        replacement.snapshot.requests.totalCount == 0,
                        vm.memoryControlStatus.generation > ownerGeneration,
                        vm.balloonState.requestGeneration == requestGeneration,
                        vm.balloonState.epoch == pre.epoch, !vm.balloonState.quarantined else {
                        throw Failure.check("replacement owner was not new and observational")
                      }
                      replacement.requestStop()
                      try await resumed.value
                    } catch {
                      resumed.cancel()
                      _ = await resumed.result
                      throw error
                    }
                    expectedGracefulStop = true
                  } else {
                    switch outcome {
                    case .success: throw Failure.check("autonomous fault returned success")
                    case .failure(let error):
                      if expectedDisconnection {
                        guard error as? NativeControlFailure == .disconnected else { throw error }
                      } else {
                        guard error is CancellationError else { throw error }
                        expectedCancellation = true
                      }
                    }
                    guard vm.memoryControlStatus.retired, final.failureError != nil else {
                      throw Failure.check("autonomous fault did not retire authority")
                    }
                    do {
                      try vm.requestBalloon(bytes: 128 << 20)
                      throw Failure.check("retired balloon admitted new ownership")
                    } catch NativeControlFailure.ownership {}
                    let refused = try NativeBalloonGovernor(
                      probe: memorySession!, vm: vm, residentTarget: geometry.maximumBytes)
                    do {
                      try await refused.run()
                      throw Failure.check("retired balloon admitted a fresh governor")
                    } catch NativeControlFailure.ownership {}
                    guard vm.memoryControlStatus.generation == ownerGeneration,
                      vm.balloonState.requestGeneration == requestGeneration,
                      vm.balloonState.epoch == pre.epoch else {
                      throw Failure.check("refused governor changed authority")
                    }
                    try await vm.waitForMemoryControlRetirement(
                      deadline: stop.advanced(by: .seconds(8)))
                  }
                  let aggregate = try await activeLoad!.value
                  activeLoad = nil
                  let actualIntegrity = try await sql(container, query: integrity)
                  guard aggregate == "4999950000", try await verify() == initialMemory,
                    actualIntegrity == expected else {
                    throw Failure.check("autonomous fault SQL/canary integrity")
                  }
                  let elapsed = faultBegan.duration(to: .now).components
                  let zero = zeroDelivery.components
                  let faultAt = vm.controlTimeOrigin.duration(to: faultBegan).components
                  let appliedAt = vm.controlTimeOrigin.duration(to: nativeZero.appliedAt).components
                  commands.append([
                    "autonomousFaultMode": mode, "ownedBytesAtFault": String(owned),
                    "nativeZeroGeneration": String(nativeZero.generation),
                    "nativeZeroEpoch": String(nativeZero.epoch),
                    "preRequestGeneration": String(pre.requestGeneration),
                    "nativeZeroOwner": String(nativeZero.owner),
                    "ownerGenerationAfter": String(vm.memoryControlStatus.generation),
                    "preLoadMemoryBytes": String(preLoad.1), "zeroLoadMemoryBytes": String(zeroLoad.1),
                    "faultSinceControlStartNanoseconds": String(
                      UInt64(faultAt.seconds) * 1_000_000_000 + UInt64(faultAt.attoseconds / 1_000_000_000)),
                    "nativeAppliedSinceControlStartNanoseconds": String(
                      UInt64(appliedAt.seconds) * 1_000_000_000
                        + UInt64(appliedAt.attoseconds / 1_000_000_000)),
                    "drainNanoseconds": String(
                      UInt64(drainDuration.seconds) * 1_000_000_000
                        + UInt64(drainDuration.attoseconds / 1_000_000_000)),
                    "zeroDeliveryNanoseconds": String(
                      UInt64(zero.seconds) * 1_000_000_000 + UInt64(zero.attoseconds / 1_000_000_000)),
                    "faultCheckNanoseconds": String(
                      UInt64(elapsed.seconds) * 1_000_000_000
                        + UInt64(elapsed.attoseconds / 1_000_000_000)),
                    "integrity": actualIntegrity, "loadResult": aggregate,
                    "authorityRetired": String(vm.memoryControlStatus.retired),
                  ])
                  try await resourceSnapshot("autonomous-fault-restored")
                  break
                }
                let releasedAt = releaseStarted
                let elapsedRelease = now() - releaseStarted
                guard elapsedRelease < 8_000_000_000 else {
                  throw Failure.check("workload release exceeded autonomous return fence")
                }
                let deadline = ContinuousClock.now.advanced(
                  by: .nanoseconds(Int64(8_000_000_000 - elapsedRelease)))
                while vm.backingRecyclingStatus.coldResidentBytes - peakRecycledResidentBytes
                  < 1 << 30
                {
                  guard balloonObserver?.snapshot.failureError == nil,
                    balloonObserver?.snapshot.running == true else {
                    throw Failure.check("autonomous balloon owner failed")
                  }
                  guard ContinuousClock.now < deadline else {
                    throw Failure.check("autonomous resident return timed out")
                  }
                  try await Task.sleep(for: .milliseconds(5))
                }
                let returnedAt = now()
                let live = try await loadState(cycle: cycle)
                guard live.0 == 1, live.1 >= 16 << 20 else {
                  throw Failure.check("SQL not live during autonomous return")
                }
                while !vm.balloonState.settled || vm.balloonState.targetBytes != 0 {
                  guard balloonObserver?.snapshot.failureError == nil,
                    ContinuousClock.now < deadline else {
                    throw Failure.check("autonomous capacity restoration timed out")
                  }
                  try await Task.sleep(for: .milliseconds(5))
                }
                let restored = try await verify()
                guard restored == initialMemory else {
                  throw Failure.check("autonomous capacity changed")
                }
                pulse = [
                  "initialGuestBytes": initialMemory, "heldGuestBytes": restored,
                  "restoredGuestBytes": restored, "releasedAtNanoseconds": releasedAt,
                  "inflatedAtNanoseconds": returnedAt, "deflatedAtNanoseconds": now(),
                  "reportedResidentBytesRecycled": vm.backingRecyclingStatus.coldResidentBytes
                    - peakRecycledResidentBytes,
                  "activeDuringBalloonMemoryBytes": live.1,
                ]
              } else {
                pulse = try await balloonPulse(cycle: cycle, minimumResidentReturn: 1 << 30)
              }
              let aggregate = try await activeLoad!.value
              activeLoad = nil
              guard aggregate == "4999950000", vm.memoryControlStatus.backingRetiredBytes == 0,
                try await sql(container, query: integrity) == expected
              else { throw Failure.check("classic pressure return/integrity") }
              try await resourceSnapshot("classic-pressure-restored-\(cycle)")
              var record: [String: Any] = pulse.mapValues { $0 as Any }
              record["cycle"] = cycle
              record["pressureTableRows"] = pressureRows
              record["heldPressureBytes"] = 2176 << 20
              record["workloadAllocatorPurgeRequested"] = true
              record["integrity"] = expected
              record["loadResult"] = aggregate
              observations.append(record)
              continue
            }
            if reporting {
              let deadline = ContinuousClock.now.advanced(by: .seconds(8))
              while vm.backingRecyclingStatus.coldResidentBytes - peakRecycledResidentBytes < 1 << 30
              {
                guard observer?.status.failure.isEmpty == true else {
                  throw Failure.check("reporting observer failed")
                }
                guard ContinuousClock.now < deadline else {
                  commands.append([
                    "reportingDeadlineRecycledResidentBytes": String(
                      vm.backingRecyclingStatus.coldResidentBytes), "capturedAt": String(now()),
                  ])
                  throw Failure.check("reported resident backing did not return")
                }
                try await Task.sleep(for: .milliseconds(5))
              }
              let active = try await loadState(cycle: cycle)
              guard active.0 == 1, active.1 >= 16 << 20 else {
                throw Failure.check("SQL not live during reporting")
              }
            }
            let aggregate = try await activeLoad!.value
            activeLoad = nil
            try await waitObserver(geometry.dynamicBytes)
            let retained = try await verify()
            guard retained == initialMemory, aggregate == "4999950000",
              observer!.minimumResidentBytes == geometry.maximumBytes,
              observer!.snapshot.requestHistory.totalCount == 0,
              vm.memoryControlStatus.backingRetiredBytes == 0,
              try await sql(container, query: integrity) == expected
            else { throw Failure.check("protected capacity/integrity") }
            try await resourceSnapshot("protected-retained-\(cycle)")
            observations.append([
              "cycle": cycle, "pressureTableRows": 557056, "heldPressureBytes": 2176 << 20,
              "protectedCapacity": true, "retiredBackingBytes": 0,
              "reportedResidentBytesRecycled": vm.backingRecyclingStatus.coldResidentBytes
                - peakRecycledResidentBytes,
              "regrownGuestBytes": pressurePeakGuest, "shrunkGuestBytes": retained,
              "activeQueryMemoryBytes": observed, "workloadAllocatorPurgeRequested": true,
              "integrity": expected, "loadResult": aggregate,
            ])
            continue
          }
          let retirementDeadline = ContinuousClock.now.advanced(by: .seconds(8))
          while vm.memoryControlStatus.backingRetiredBytes == pressurePeakBacking {
            guard ContinuousClock.now < retirementDeadline,
              observer?.status.failure.isEmpty == true
            else { throw Failure.check("pressure retirement did not begin") }
            try await Task.sleep(for: .milliseconds(5))
          }
          let activeDuringRetirement = try await loadState(cycle: cycle)
          guard activeDuringRetirement.0 == 1, activeDuringRetirement.1 >= 16 << 20 else {
            throw Failure.check("SQL not live during native backing retirement")
          }
          let aggregate = try await activeLoad!.value
          activeLoad = nil
          try await waitObserver(0, deadline: .now.advanced(by: .seconds(30)))
          let shrunk = try await verify()
          let retired = vm.memoryControlStatus.backingRetiredBytes - pressurePeakBacking
          guard shrunk == bootGuestBytes, retired == geometry.dynamicBytes,
            aggregate == "4999950000", try await sql(container, query: integrity) == expected
          else { throw Failure.check("pressure return/integrity") }
          try await resourceSnapshot("pressure-returned-\(cycle)")
          observations.append([
            "cycle": cycle, "pressureTableRows": 557056, "heldPressureBytes": 2176 << 20,
            "workloadAllocatorPurgeRequested": true,
            "regrownGuestBytes": pressurePeakGuest, "shrunkGuestBytes": shrunk,
            "retiredBackingBytes": retired,
            "activeDuringFirstRetirementMemoryBytes": activeDuringRetirement.1,
            "integrity": expected, "loadResult": aggregate,
          ])
          continue
        }
        if continuous {
          _ = try await verify("HOLD")
          try await waitObserver(nil)
          let grown = vm.pluggedBytes
          let regrown = try await verify("OBS")
          _ = try await verify("DROP")
          try await waitObserver(0)
          let stillRunning = try await loadState(cycle: cycle)
          guard stillRunning.0 == 1, stillRunning.1 >= 16 << 20 else {
            throw Failure.check("continuous load not live after unplug")
          }
          let shrunk = try await verify()
          guard initialMemory >= shrunk, initialMemory - shrunk == geometry.dynamicBytes,
            grown > 0, grown <= geometry.dynamicBytes, regrown == shrunk + grown
          else { throw Failure.check("continuous guest capacity") }
          try await resourceSnapshot("continuous-shrunk-\(cycle)")
          let aggregate = try await activeLoad!.value
          activeLoad = nil
          guard aggregate == "4999950000",
            try await sql(container, query: integrity) == expected
          else { throw Failure.check("continuous aggregate/integrity") }
          observations.append([
            "cycle": cycle, "activeQueryMemoryBytes": observed,
            "activeAfterUnplugMemoryBytes": stillRunning.1,
            "restoredBackingBytes": grown, "shrunkGuestBytes": shrunk,
            "regrownGuestBytes": regrown, "integrity": expected, "loadResult": aggregate,
          ])
          continue
        }
        let cycleInitial = try await verify()
        let cyclePlugged = vm.pluggedBytes
        let unplugDeadline = ContinuousClock.now.advanced(by: .seconds(8))
        if adaptive {
          let issued = policyRequests.count
          try control()
          guard policyRequests.count == issued + 1,
            policyRequests.last?["targetBytes"] == geometry.bootBytes
          else {
            throw Failure.check("real idle headroom did not authorize reclaim")
          }
        } else {
          try vm.requestMemory(bytes: 0)
        }
        if mode == "crash" {
          let path = output.appending(path: "CRASH_READY.pending")
          try JSONSerialization.data(withJSONObject: [
            "pid": getpid(), "rows": 400000,
            "activeQuery": true, "activeQueryMemoryBytes": observed, "durableInserts": true,
            "cpus": vm.processorCount, "nics": vm.networkCount,
          ]).write(to: path, options: .withoutOverwriting)
          let journal = try FileHandle(forWritingTo: path)
          try journal.synchronize()
          try journal.close()
          let published = output.appending(path: "CRASH_READY.json")
          guard renamex_np(path.path, published.path, UInt32(RENAME_EXCL)) == 0 else {
            throw Failure.check("publish crash point")
          }
          let directory = open(output.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
          guard directory >= 0 else { throw Failure.check("crash directory") }
          let sync = fsync(directory)
          let closed = close(directory)
          guard sync == 0, closed == 0 else { throw Failure.check("sync crash directory") }
          try await Task.sleep(for: .seconds(3))
          throw Failure.check("owner was not killed by its supervisor")
        }
        if cycle == 1, vm.aliasDiagnosticEnabled, !adaptive {
          try vm.releaseDiagnosticAlias()
        }
        if adaptive {
          _ = try await settle(0)
        } else {
          try await waitMemory(vm, bytes: 0, deadline: unplugDeadline)
        }
        let stillRunning = try await loadState(cycle: cycle)
        commands.append(["afterUnplugQueryState": "\(stillRunning.0)\t\(stillRunning.1)"])
        let memoryAfterUnplug = stillRunning.1
        guard stillRunning.0 == 1, memoryAfterUnplug >= 16 << 20
        else { throw Failure.check("load not live after unplug: \(stillRunning)") }
        let shrunk = try await waitGuestMemory(bootGuestBytes, deadline: unplugDeadline)
        try await resourceSnapshot("shrunk-\(cycle)")
        guard initialMemory >= shrunk, cycleInitial >= shrunk,
          cycleInitial - shrunk == cyclePlugged, cyclePlugged > 0,
          initialMemory - shrunk == geometry.dynamicBytes
        else {
          throw Failure.check("guest capacity not reduced")
        }
        let loadResult = try await activeLoad!.value
        activeLoad = nil
        guard loadResult == "4999950000" else {
          throw Failure.check("load aggregate " + loadResult)
        }
        guard try await sql(container, query: integrity) == expected else {
          throw Failure.check("post shrink data")
        }
        let regrown: UInt64
        if adaptive {
          _ = try await verify("HOLD")
          let pressureAvailable = available
          let issued = policyRequests.count
          try control()
          guard policyRequests.count == issued + 1,
            let growth = governor.pendingRequest,
            growth.targetResidentBytes > geometry.bootBytes,
            growth.targetResidentBytes <= geometry.maximumBytes,
            pressureAvailable < 512 << 20
          else { throw Failure.check("real guest pressure did not authorize growth") }
          try await resourceSnapshot("pressure-\(cycle)")
          regrown = try await settle(growth.targetResidentBytes - geometry.bootBytes)
          // The checked private allocation is released only after actual growth has completed.
          _ = try await verify("DROP")
          commands.append([
            "pressureAvailableBytes": String(pressureAvailable),
            "releasedAvailableBytes": String(available),
            "pressureAllocationBytes": String(320 << 20),
          ])
          try await Task.sleep(for: .milliseconds(350))
        } else {
          let deadline = ContinuousClock.now.advanced(by: .seconds(8))
          try vm.requestMemory(bytes: geometry.dynamicBytes)
          try await waitMemory(vm, bytes: geometry.dynamicBytes, deadline: deadline)
          regrown = try await waitGuestMemory(initialMemory, deadline: deadline)
        }
        let restored = vm.pluggedBytes
        guard restored > 0, restored <= geometry.dynamicBytes,
          regrown == shrunk + restored
        else { throw Failure.check("guest capacity not restored to the policy target") }
        try await resourceSnapshot("regrown-\(cycle)")
        observations.append([
          "cycle": cycle, "activeQueryMemoryBytes": observed,
          "activeAfterUnplugMemoryBytes": memoryAfterUnplug,
          "initialGuestBytes": cycleInitial, "shrunkGuestBytes": shrunk,
          "retiredBackingBytes": cyclePlugged, "restoredBackingBytes": restored,
          "regrownGuestBytes": regrown, "integrity": expected, "loadResult": loadResult,
        ])
      }
      if mode == "continuous-churn" {
        var completedRetirements: UInt64 = 0
        for cycle in 3...48 {
          _ = try await verify("HOLD")
          try await waitObserver(nil)
          let grown = vm.pluggedBytes
          guard grown > 0 else { throw Failure.check("churn regrowth") }
          _ = try await verify("DROP")
          try await waitObserver(0)
          _ = try await verify()
          churn.append(["cycle": UInt64(cycle), "regrownBackingBytes": grown])
          completedRetirements += grown
          if cycle % 4 == 0 {
            guard try await sql(container, query: integrity) == expected else {
              throw Failure.check("churn durable integrity")
            }
          }
          if completedRetirements > 2 << 30,
            observer!.snapshot.requestHistory.totalCount > 32
          {
            break
          }
        }
        guard let observer, observer.snapshot.requestHistory.totalCount > 32,
          completedRetirements > 2 << 30
        else {
          throw Failure.check("request and native retirement histories did not wrap")
        }
        try await resourceSnapshot("request-history-wrapped")
      }
      if mode == "continuous-soak", let observer {
        while observer.status.sampleCount < 520 {
          guard observer.status.running, observer.status.failure.isEmpty else {
            throw Failure.check("continuous soak ended before history wrap")
          }
          try await Task.sleep(for: .milliseconds(100))
        }
        guard try await sql(container, query: integrity) == expected else {
          throw Failure.check("soak integrity")
        }
        try await resourceSnapshot("history-wrapped")
      }
      if mode == "continuous-sustained", let observer {
        var checkedAt = ContinuousClock.now
        while began.duration(to: .now) < .seconds(125) {
          guard observer.status.running, observer.status.failure.isEmpty else {
            throw Failure.check("sustained governor ended")
          }
          if checkedAt.duration(to: .now) >= .seconds(10) {
            guard try await sql(container, query: integrity) == expected else {
              throw Failure.check("sustained integrity")
            }
            try await resourceSnapshot("sustained-checkpoint")
            checkedAt = .now
          }
          try await Task.sleep(for: .milliseconds(200))
        }
        guard try await sql(container, query: integrity) == expected else {
          throw Failure.check("sustained final integrity")
        }
        commands.append(["sustainedWorkloadNanoseconds": String(now())])
        try await resourceSnapshot("sustained-past-original-vmm-deadline")
      }
      if let observer, let task = observerTask {
        observer.requestStop()
        try await task.value
        observerTask = nil
        guard !observer.status.running else { throw Failure.check("observer still running") }
      }
      if let balloonObserver, let task = balloonTask {
        // Join synthetic CPU/NIC beacons; the 64 MiB canary remains live and checked afterward.
        _ = try await verify("QUIESCE")
        let idleStart = ContinuousClock.now
        let initial = balloonObserver.snapshot
        let memoryBefore = try ProcessMemorySnapshot.capture()
        var cpuBefore = rusage()
        guard getrusage(RUSAGE_SELF, &cpuBefore) == 0 else { throw Failure.check("idle CPU") }
        while idleStart.duration(to: .now) < .seconds(30) {
          guard balloonObserver.snapshot.running,
            balloonObserver.snapshot.failureError == nil else {
            throw Failure.check("autonomous idle owner failed")
          }
          try await Task.sleep(for: .seconds(1))
        }
        let idle = balloonObserver.snapshot
        let memoryAfter = try ProcessMemorySnapshot.capture()
        var cpuAfter = rusage()
        guard getrusage(RUSAGE_SELF, &cpuAfter) == 0 else { throw Failure.check("idle CPU") }
        func microseconds(_ usage: rusage) -> Int {
          usage.ru_utime.tv_sec * 1_000_000 + Int(usage.ru_utime.tv_usec)
            + usage.ru_stime.tv_sec * 1_000_000 + Int(usage.ru_stime.tv_usec)
        }
        commands.append([
          "autonomousIdleNanoseconds": String(now()),
          "syntheticBeaconsQuiesced": "true",
          "idlePulses": String(idle.completedPulses - initial.completedPulses),
          "idleRequests": String(idle.requests.totalCount - initial.requests.totalCount),
          "idleSamples": String(idle.samples.totalCount - initial.samples.totalCount),
          "idleCPUUsec": String(microseconds(cpuAfter) - microseconds(cpuBefore)),
          "idleFootprintBefore": String(memoryBefore.physicalFootprintBytes ?? 0),
          "idleFootprintAfter": String(memoryAfter.physicalFootprintBytes ?? 0),
        ])
        _ = try await verify()
        guard try await sql(container, query: integrity) == expected else {
          throw Failure.check("post-idle integrity")
        }
        try await resourceSnapshot("autonomous-idle")
        balloonObserver.requestStop()
        try await task.value
        balloonTask = nil
        let final = balloonObserver.snapshot
        guard !final.running, !final.pending, final.failureError == nil,
          final.cleanupError == nil, final.completedPulses >= 2,
          vm.balloonState.settled, vm.balloonState.targetBytes == 0,
          !vm.memoryControlStatus.retired else {
          throw Failure.check("autonomous balloon owner did not drain")
        }
      }
      _ = try await verify(quit: true)
      input.finish()
      guard try await canary!.wait(timeoutInSeconds: 5).exitCode == 0 else {
        throw Failure.check("canary exit")
      }
      try await canary!.delete()
      canary = nil
      if let memorySession {
        if expectedCancellation || expectedLifetimeExpiry || expectedDisconnection {
          await memorySession.close()
        } else {
          try await memorySession.quit()
        }
      }
      if let memoryMonitor {
        let status = try await memoryMonitor.wait(timeoutInSeconds: 5)
        // Closing the owned input intentionally retires this strict command protocol with exit1.
        let expectedExit: Int32 = expectedCancellation || expectedLifetimeExpiry || expectedDisconnection ? 1 : 0
        commands.append(["memoryMonitorExit": String(status.exitCode)])
        guard status.exitCode == expectedExit else {
          throw Failure.check("memory monitor exit")
        }
        try await memoryMonitor.delete()
      }
      memoryMonitor = nil
    } catch {
      primary = String(describing: error)
      if classic, !autonomousBalloon {
        do {
          try vm.requestBalloon(bytes: 0)
          let deadline = ContinuousClock.now.advanced(by: .seconds(8))
          while vm.balloonState.ownedBytes != 0 || !vm.balloonState.settled {
            guard ContinuousClock.now < deadline else { throw Failure.check("balloon rescue drain") }
            try await Task.sleep(for: .milliseconds(5))
          }
        } catch { cleanup.append("balloon-rescue \(error)") }
      }
      if reporting, case Failure.check(let reason) = error,
        reason == "reported resident backing did not return"
      {
        // Preserve the failed eight-second gate; later observations cannot turn it into a pass.
        let diagnosticBegan = ContinuousClock.now
        do {
          for delay in [0, 10, 20, 30] {
            try await Task.sleep(until: diagnosticBegan.advanced(by: .seconds(delay)))
            commands.append([
              "reportingDiagnosticSecondsAfterFailure": String(delay),
              "recycledResidentBytes": String(vm.backingRecyclingStatus.coldResidentBytes),
              "capturedAt": String(now()),
            ])
            print("REPORTING_FOLLOWUP \(delay) \(vm.backingRecyclingStatus.residentBytes)")
            fflush(nil)
          }
        } catch { memoryDiagnostics.append(["reportingFollowupError": String(describing: error)]) }
      }
      if pressureWide {
        for (name, query) in [
          (
            "server-settings",
            "SELECT name, value FROM system.server_settings WHERE name IN ('max_server_memory_usage','max_server_memory_usage_to_ram_ratio','memory_worker_use_cgroup','memory_worker_dynamic_hard_limit','memory_worker_rss_speculative_reserve_ratio','cgroups_memory_usage_observer_wait_time') LIMIT 8"
          ),
          (
            "async-memory",
            "SELECT metric, value FROM system.asynchronous_metrics WHERE metric LIKE '%Memory%' LIMIT 100"
          ),
          (
            "current-memory",
            "SELECT metric, value FROM system.metrics WHERE metric LIKE '%Memory%' LIMIT 100"
          ),
        ] {
          do {
            memoryDiagnostics.append([
              "kind": name, "reply": try await sql(container, query: query),
            ])
          } catch {
            memoryDiagnostics.append(["kind": name, "error": String(describing: error)])
          }
        }
      }
    }
    if let task = balloonTask {
      balloonObserver?.requestStop()
      task.cancel()
      switch await task.result {
      case .success: break
      case .failure(let error):
        if !(error is CancellationError) { cleanup.append("autonomous-balloon-stop \(error)") }
      }
      if let error = balloonObserver?.snapshot.cleanupError {
        cleanup.append("autonomous-balloon-drain \(error)")
      }
    }
    if let task = observerTask {
      task.cancel()
      switch await task.result {
      case .success: break
      case .failure(let error):
        if !(error is CancellationError) { cleanup.append("observer-stop \(error)") }
      }
    }
    await session.close()
    await memorySession?.close()
    input.finish()
    for (name, process) in [("canary", canary), ("memory monitor", memoryMonitor)] {
      guard let process else { continue }
      let failures = await Task { @concurrent in
        var errors: [String] = []
        do {
          // Closed stdin can retire the guest before a kill request reaches vminitd.
          _ = try await process.wait(timeoutInSeconds: 1)
        } catch {
          do { try await process.kill(.kill) } catch { errors.append("\(name) kill \(error)") }
          do { _ = try await process.wait(timeoutInSeconds: 5) } catch {
            errors.append("\(name) wait \(error)")
          }
        }
        do { try await process.delete() } catch { errors.append("\(name) delete \(error)") }
        return errors
      }.value
      cleanup += failures
    }
    if let activeLoad {
      // SQL's own finite wait/kill/delete must retire before VM stop.
      switch await activeLoad.result {
      case .success(let result): commands.append(["retiredLoadResult": result])
      case .failure(let error): commands.append(["retiredLoadFailure": String(describing: error)])
      }
    }
    let transcript = await session.transcript
    let observerState = observer?.snapshot
    var observerStopNanoseconds: Any = NSNull()
    if let instant = observerState?.stopRequestedAt {
      let value = began.duration(to: instant).components
      observerStopNanoseconds =
        UInt64(value.seconds) * 1_000_000_000
        + UInt64(value.attoseconds / 1_000_000_000)
    }
    let result: [String: Any] = [
      "primaryError": primary, "cleanupErrors": cleanup,
      "cycles": observations, "canaryTranscript": transcript, "commands": commands,
      "churn": churn,
      "pressureWide": pressureWide, "containerMemoryLimitBytes": memoryLimit,
      "protectedCapacityControl": protectedCapacity,
      "minimumResidentBytes": observer.map { $0.minimumResidentBytes as Any } ?? NSNull(),
      "memoryDiagnostics": memoryDiagnostics,
      "canaryTranscriptTotal": await session.transcriptTotal,
      "canaryTranscriptDropped": await session.transcriptDropped,
      "canaryBytes": 64 << 20, "rows": 400000, "resources": resources,
      "adaptive": adaptive, "policyRequests": policyRequests, "policySamples": policySamples,
      "classicBallooning": classic, "autonomousBallooning": autonomousBalloon,
      "pressurePayload": entropyPressure ? "random-string-4096-bytes" : "repeated-hash-control",
      "balloonObserverRequests": balloonObserver?.snapshot.requests.elements ?? [],
      "balloonObserverSamples": balloonObserver?.snapshot.samples.elements ?? [],
      "balloonObserverRequestsTotal": balloonObserver?.snapshot.requests.totalCount ?? 0,
      "balloonObserverCompletedPulses": balloonObserver?.snapshot.completedPulses ?? 0,
      "balloonObserverStopped": balloonObserver?.snapshot.running == false,
      "balloonObserverFailure": balloonObserver?.snapshot.failureError.map {
        String(describing: $0)
      } ?? "",
      "balloonObserverCleanupFailure": balloonObserver?.snapshot.cleanupError.map {
        String(describing: $0)
      } ?? "",
      "continuous": continuous, "observerSamples": observerState?.samples ?? [],
      "observerRequests": observerState?.requests ?? [],
      "observerSamplesTotal": observerState?.sampleHistory.totalCount ?? 0,
      "observerSamplesDropped": observerState?.sampleHistory.droppedCount ?? 0,
      "observerRequestsTotal": observerState?.requestHistory.totalCount ?? 0,
      "observerRequestsDropped": observerState?.requestHistory.droppedCount ?? 0,
      "observerPending": observerState?.pending ?? false,
      "observerCapacityReady": observerState?.capacityReady ?? false,
      "observerActiveRequest": observerState?.activeRequest ?? [:],
      "observerStopped": observerState?.running == false,
      "observerStopRequestedAt": observerStopNanoseconds,
      "observerFailure": observerState?.failure ?? "", "expectedCancellation": expectedCancellation,
      "expectedGracefulStop": expectedGracefulStop,
      "expectedLifetimeExpiry": expectedLifetimeExpiry,
      "expectedDisconnection": expectedDisconnection,
    ]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appending(path: "workload.json"), options: .withoutOverwriting)
    guard primary.isEmpty, cleanup.isEmpty,
      expectedCancellation || expectedGracefulStop || expectedLifetimeExpiry || expectedDisconnection
        || observations.count == 2
    else {
      throw Failure.check(primary)
    }
    return true
  }
}
