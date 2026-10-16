import BoundedMemory
import Containerization
import Darwin
import Foundation
import NativeLinuxVMM

extension Lab {
  static func sql(
    _ container: LinuxContainer, id: String = UUID().uuidString,
    query: String, queryID: String? = nil
  ) async throws -> String {
    let output = BoundedOutput()
    let process = try await container.exec(id) { config in
      config.arguments = [
        "/usr/bin/clickhouse", "client", "--host=127.0.0.1", "--port=9000",
        "--format=TSVRaw", "--receive_timeout=10", "--send_timeout=3", "--connect_timeout=2",
        "--max_threads=1", "--max_memory_usage=201326592", "--max_execution_time=8",
        "--timeout_before_checking_execution_speed=0", "--max_rows_to_read=500000",
        "--max_bytes_to_read=100663296", "--max_result_rows=1000",
      ]
      if let queryID { config.arguments += ["--query_id", queryID] }
      config.arguments += ["--query", query]
      config.stdout = output
      config.stderr = output
      config.noNewPrivileges = true
    }
    let status: Int32
    do {
      try await process.start()
      status = try await process.wait(timeoutInSeconds: 12).exitCode
    } catch {
      let failures = await Task { @concurrent in
        var errors: [String] = []
        do { try await process.kill(.kill) } catch { errors.append("kill \(error)") }
        do { try await process.delete() } catch { errors.append("delete \(error)") }
        return errors
      }.value
      throw Failure.check("\(error) cleanup=\(failures)")
    }
    try await process.delete()
    guard status == 0, !output.overflowed else {
      throw Failure.check("SQL " + output.text)
    }
    return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
    var commands: [[String: String]] = []
    var observations: [[String: Any]] = []
    var resources: [[String: Any]] = []
    var policySamples: [[String: Any]] = []
    var policyRequests: [[String: UInt64]] = []
    let adaptive = ["adaptive", "adaptive-busy"].contains(mode)
    let continuous = [
      "continuous", "continuous-cancel", "continuous-soak", "continuous-stop", "continuous-churn",
      "continuous-expire",
    ].contains(mode)
    var churn: [[String: UInt64]] = []
    var expectedGracefulStop = false
    var expectedLifetimeExpiry = false
    var observer: ContinuousMemoryGovernor?
    var observerTask: Task<Void, Error>?
    var expectedCancellation = false
    let began = ContinuousClock.now
    func now() -> UInt64 {
      let elapsed = began.duration(to: .now).components
      return UInt64(elapsed.seconds) * 1_000_000_000 + UInt64(elapsed.attoseconds / 1_000_000_000)
    }
    guard let budget = BalloonBudget(
      installedBytes: 1152 << 20, minimumResidentBytes: 1024 << 20,
      granuleBytes: 2 << 20, maximumStepBytes: 128 << 20),
      var governor = BalloonController(
        budget: budget, epoch: 1, guestReserveBytes: 512 << 20, hysteresisBytes: 32 << 20,
        maximumObservationAgeNanoseconds: 3_000_000_000, cooldownNanoseconds: 300_000_000,
        completionTimeoutNanoseconds: 8_000_000_000)
    else { throw Failure.check("policy geometry") }
    defer { governor.retire() }
    let input = CommandInput()
    let canaryOutput = ProbeOutput()
    let session = MemoryProbeSession(
      input: input, output: canaryOutput, cpus: vm.processorCount, began: began)
    var canary: LinuxProcess?
    var activeLoad: Task<String, Error>?
    var primary = ""
    var cleanup: [String] = []
    // writeFile(create:) does not truncate; a recovered filesystem can contain an older probe.
    let guestProbe = "/lab/canary-" + UUID().uuidString.lowercased()
    do {
      let agent = try await vm.dialAgent()
      do {
        let handle = try FileHandle(forReadingFrom: probe)
        defer { try? handle.close() }
        var written = 0
        while let bytes = try handle.read(upToCount: 65536), !bytes.isEmpty {
          guard bytes.count <= (8 << 20) - written else { throw Failure.check("probe size") }
          try await agent.writeFile(
            path: "/run/container/swiftos-native/rootfs" + guestProbe, data: bytes,
            flags: .init(create: written == 0, append: written != 0), mode: 0o700)
          written += bytes.count
        }
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
      guard initialMemory >= 128 << 20, initialMemory <= 1152 << 20 else {
        throw Failure.check("initial guest geometry")
      }
      let bootGuestBytes = initialMemory - (128 << 20)
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
        capturedAt = reply.capturedAt
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
          actualResidentBytes: (1024 << 20) + state.pluggedBytes,
          requestedResidentBytes: (1024 << 20) + state.requestedBytes,
          guestAvailableBytes: available, hostResidentLimitBytes: 1152 << 20,
          hostUnderPressure: pressure != 1, guestUnderPressure: false)
        let request = try governor.observe(sample, nowNanoseconds: returnedAt)
        if let request {
          try vm.requestMemory(bytes: request.targetResidentBytes - (1024 << 20))
          let deliveredAt = now()
          try governor.didApply(
            request, afterObservationSequence: UInt64(sequence), atNanoseconds: deliveredAt)
          policyRequests.append([
            "initialBytes": request.initialResidentBytes, "targetBytes": request.targetResidentBytes,
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
          { return total }
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
      func waitObserver(_ bytes: UInt64?) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        guard let observer else { throw Failure.check("observer missing") }
        repeat {
          try Task.checkCancellation()
          let status = observer.status
          guard status.failure.isEmpty else { throw Failure.check("observer " + status.failure) }
          if status.running, status.sampleCount > 0, !status.pending, status.capacityReady,
            bytes.map({ vm.pluggedBytes == $0 }) ?? (vm.pluggedBytes > 0)
          { return }
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
          resources.append([
            "phase": phase, "usageBytes": memory.usageBytes,
            "limitBytes": memory.limitBytes, "swapBytes": memory.swapUsageBytes,
            "cacheBytes": memory.cacheBytes, "anonBytes": memory.anon,
            "oom": events.oom, "oomKill": events.oomKill, "maxEvents": events.max,
            "highEvents": events.high, "cpuUsageUsec": values[0].cpu?.usageUsec ?? 0,
          ])
          // memory.max events include successful file-cache reclaim, not only OOM failures.
          guard events.oom == 0, events.oomKill == 0,
            memory.limitBytes == 896 << 20, memory.usageBytes <= memory.limitBytes
          else { throw Failure.check("cgroup limits/OOM \(resources.last!)") }
        } catch {
          try? await agent.close()
          throw error
        }
      }
      try await waitMemory(vm, bytes: 128 << 20)
      try await resourceSnapshot("baseline")
      if continuous {
        let driver = ContinuousMemoryGovernor(
          probe: session, vm: vm, began: began, bootGuestBytes: bootGuestBytes,
          lifetimeDeadline: mode == "continuous-expire"
            ? .now.advanced(by: .seconds(2)) : began.advanced(by: .seconds(180)),
          samplingInterval: mode == "continuous-soak" ? .milliseconds(100) : .milliseconds(200))
        observer = driver
        observerTask = Task { try await driver.run() }
        if mode == "continuous-expire" {
          switch await observerTask!.result {
          case .success: throw Failure.check("observer ignored lifetime deadline")
          case .failure(let error):
            guard error as? LabFailure == .deadline else { throw error }
          }
          observerTask = nil
          let expired = driver.snapshot
          guard !expired.running, !expired.pending, expired.capacityReady,
            expired.requestHistory.totalCount == 0,
            try await sql(container, query: integrity) == expected
          else { throw Failure.check("deadline admission/status/integrity") }
          expectedLifetimeExpiry = true
          try await resourceSnapshot("lifetime-expired-without-new-admission")
        } else if mode == "continuous-cancel" || mode == "continuous-stop" {
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
          guard !driver.status.running, try await sql(container, query: integrity) == expected else {
            throw Failure.check("cancel retirement/integrity")
          }
          try await resourceSnapshot("cancelled-pending")
          }
        } else { try await waitObserver(0) }
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
        try vm.requestMemory(bytes: 128 << 20)
      }
      for cycle in (expectedCancellation || expectedGracefulStop || expectedLifetimeExpiry ? [] : [1, 2]) {
        let queryID = "swiftos-load-\(cycle)"
        let query =
          "SELECT sum(n.number + sleepEachRow(0.00004)) FROM numbers(100000) AS n INNER JOIN (SELECT id, payload FROM default.ram_lab WHERE id < 100000) AS r ON n.number = r.id AND repeat(hex(cityHash64(n.number)), 8) = r.payload LIMIT 1 SETTINGS join_algorithm='hash'"
        activeLoad = Task { try await sql(container, query: query, queryID: queryID) }
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
          guard initialMemory >= shrunk, initialMemory - shrunk == 128 << 20,
            grown > 0, grown <= 128 << 20, regrown == shrunk + grown
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
            policyRequests.last?["targetBytes"] == 1024 << 20
          else {
            throw Failure.check("real idle headroom did not authorize reclaim")
          }
        } else { try vm.requestMemory(bytes: 0) }
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
        if adaptive { _ = try await settle(0) }
        else { try await waitMemory(vm, bytes: 0, deadline: unplugDeadline) }
        let stillRunning = try await loadState(cycle: cycle)
        commands.append(["afterUnplugQueryState": "\(stillRunning.0)\t\(stillRunning.1)"])
        let memoryAfterUnplug = stillRunning.1
        guard stillRunning.0 == 1, memoryAfterUnplug >= 16 << 20
        else { throw Failure.check("load not live after unplug: \(stillRunning)") }
        let shrunk = try await waitGuestMemory(bootGuestBytes, deadline: unplugDeadline)
        try await resourceSnapshot("shrunk-\(cycle)")
        guard initialMemory >= shrunk, cycleInitial >= shrunk,
          cycleInitial - shrunk == cyclePlugged, cyclePlugged > 0, initialMemory - shrunk == 128 << 20
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
            growth.targetResidentBytes > 1024 << 20,
            growth.targetResidentBytes <= 1152 << 20,
            pressureAvailable < 512 << 20
          else { throw Failure.check("real guest pressure did not authorize growth") }
          try await resourceSnapshot("pressure-\(cycle)")
          regrown = try await settle(growth.targetResidentBytes - (1024 << 20))
          // The checked private allocation is released only after actual growth has completed.
          _ = try await verify("DROP")
          commands.append([
            "pressureAvailableBytes": String(pressureAvailable),
            "releasedAvailableBytes": String(available), "pressureAllocationBytes": String(320 << 20),
          ])
          try await Task.sleep(for: .milliseconds(350))
        } else {
          let deadline = ContinuousClock.now.advanced(by: .seconds(8))
          try vm.requestMemory(bytes: 128 << 20)
          try await waitMemory(vm, bytes: 128 << 20, deadline: deadline)
          regrown = try await waitGuestMemory(initialMemory, deadline: deadline)
        }
        let restored = vm.pluggedBytes
        guard restored > 0, restored <= 128 << 20,
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
        for cycle in 3...20 {
          _ = try await verify("HOLD")
          try await waitObserver(nil)
          let grown = vm.pluggedBytes
          guard grown > 0 else { throw Failure.check("churn regrowth") }
          _ = try await verify("DROP")
          try await waitObserver(0)
          _ = try await verify()
          churn.append(["cycle": UInt64(cycle), "regrownBackingBytes": grown])
          if cycle % 4 == 0 {
            guard try await sql(container, query: integrity) == expected else {
              throw Failure.check("churn durable integrity")
            }
          }
        }
        guard let observer, observer.snapshot.requestHistory.totalCount > 32 else {
          throw Failure.check("request history did not wrap")
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
      if let observer, let task = observerTask {
        observer.requestStop()
        try await task.value
        observerTask = nil
        guard !observer.status.running else { throw Failure.check("observer still running") }
      }
      if !expectedCancellation { _ = try await verify(quit: true) }
      input.finish()
      if !expectedCancellation {
        guard try await canary!.wait(timeoutInSeconds: 5).exitCode == 0 else {
          throw Failure.check("canary exit")
        }
        try await canary!.delete()
        canary = nil
      }
    } catch { primary = String(describing: error) }
    if let task = observerTask {
      task.cancel()
      switch await task.result {
      case .success: break
      case .failure(let error):
        if !(error is CancellationError) { cleanup.append("observer-stop \(error)") }
      }
    }
    await session.close()
    input.finish()
    if let canary {
      let failures = await Task { @concurrent in
        var errors: [String] = []
        do {
          // Closed stdin can retire the guest before a kill request reaches vminitd.
          _ = try await canary.wait(timeoutInSeconds: 1)
        } catch {
          do { try await canary.kill(.kill) } catch { errors.append("canary kill \(error)") }
          do { _ = try await canary.wait(timeoutInSeconds: 5) }
          catch { errors.append("canary wait \(error)") }
        }
        do { try await canary.delete() } catch { errors.append("canary delete \(error)") }
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
    let result: [String: Any] = [
      "primaryError": primary, "cleanupErrors": cleanup,
      "cycles": observations, "canaryTranscript": transcript, "commands": commands,
      "churn": churn,
      "canaryTranscriptTotal": await session.transcriptTotal,
      "canaryTranscriptDropped": await session.transcriptDropped,
      "canaryBytes": 64 << 20, "rows": 400000, "resources": resources,
      "adaptive": adaptive, "policyRequests": policyRequests, "policySamples": policySamples,
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
      "observerFailure": observerState?.failure ?? "", "expectedCancellation": expectedCancellation,
      "expectedGracefulStop": expectedGracefulStop,
      "expectedLifetimeExpiry": expectedLifetimeExpiry,
    ]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appending(path: "workload.json"), options: .withoutOverwriting)
    guard primary.isEmpty, cleanup.isEmpty,
      expectedCancellation || expectedGracefulStop || expectedLifetimeExpiry || observations.count == 2 else {
      throw Failure.check(primary)
    }
    return true
  }
}
