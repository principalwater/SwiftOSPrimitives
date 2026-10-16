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
  static func waitMemory(_ vm: NativeVirtualMachine, bytes: UInt64) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
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
    var transcript: [String] = []
    var resources: [[String: Any]] = []
    let input = CommandInput()
    let canaryOutput = ProbeOutput()
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
      func line() async throws -> String {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < end {
          if let text = try canaryOutput.takeLine() { return text }
          try await Task.sleep(for: .milliseconds(5))
        }
        throw Failure.check("canary deadline")
      }
      let first = try await line()
      transcript.append(first)
      let initialFields = first.split(separator: " ")
      guard initialFields.count == 5 + vm.processorCount, initialFields[0] == "CANARY_READY",
        let initialMemory = UInt64(initialFields[1])
      else { throw Failure.check(first) }
      var previousWork = [UInt64](repeating: 0, count: vm.processorCount)
      var previousPackets: UInt64 = 0
      func checkWork(_ fields: ArraySlice<Substring>) throws {
        var counters: [String: UInt64] = [:]
        for field in fields {
          let pair = field.split(separator: "=")
          guard pair.count == 2, let number = UInt64(pair[1]), counters[String(pair[0])] == nil
          else { throw Failure.check("probe fields") }
          counters[String(pair[0])] = number
        }
        guard counters["cpus"] == UInt64(vm.processorCount),
          let packets = counters["packets"], packets > previousPackets
        else { throw Failure.check("NIC progress") }
        for core in 0..<vm.processorCount {
          guard let work = counters["cpu\(core)"], work > previousWork[core] else {
            throw Failure.check("CPU progress")
          }
          previousWork[core] = work
        }
        previousPackets = packets
      }
      try checkWork(initialFields.dropFirst(3))
      let engine = try await sql(
        container,
        query:
          "SELECT engine_full FROM system.tables WHERE database='default' AND name='ram_lab' LIMIT 1"
      )
      guard engine.contains("fsync_after_insert = 1"), engine.contains("fsync_part_directory = 1")
      else { throw Failure.check("durability settings") }
      commands.append(["effectiveEngine": engine])
      var sequence = 0
      func verify(quit: Bool = false) async throws -> UInt64 {
        sequence += 1
        try input.send(Data("\(quit ? "QUIT" : "VERIFY") \(sequence)\n".utf8))
        let text = try await line()
        transcript.append(text)
        let fields = text.split(separator: " ")
        guard fields.count == 6 + vm.processorCount, fields[0] == "CANARY_OK",
          Int(fields[1]) == sequence,
          let total = UInt64(fields[2])
        else { throw Failure.check(text) }
        try checkWork(fields.dropFirst(4))
        return total
      }
      func loadState(cycle: Int) async throws -> (Int, UInt64) {
        sequence += 1
        try input.send(Data("STATE \(sequence) \(cycle)\n".utf8))
        let text = try await line()
        transcript.append(text)
        let fields = text.split(separator: " ")
        guard fields.count == 4, fields[0] == "LOAD_STATE", Int(fields[1]) == sequence,
          let count = Int(fields[2]), (0...1).contains(count), let memory = UInt64(fields[3])
        else { throw Failure.check(text) }
        return (count, memory)
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
      if vm.aliasDiagnosticEnabled {
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
      for cycle in 1...2 {
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
        try vm.requestMemory(bytes: 0)
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
        if cycle == 1, vm.aliasDiagnosticEnabled {
          try vm.releaseDiagnosticAlias()
        }
        try await waitMemory(vm, bytes: 0)
        let stillRunning = try await loadState(cycle: cycle)
        commands.append(["afterUnplugQueryState": "\(stillRunning.0)\t\(stillRunning.1)"])
        let memoryAfterUnplug = stillRunning.1
        guard stillRunning.0 == 1, memoryAfterUnplug >= 16 << 20
        else { throw Failure.check("load not live after unplug: \(stillRunning)") }
        let shrunk = try await verify()
        try await resourceSnapshot("shrunk-\(cycle)")
        guard initialMemory >= shrunk, initialMemory - shrunk == 128 << 20 else {
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
        try vm.requestMemory(bytes: 128 << 20)
        try await waitMemory(vm, bytes: 128 << 20)
        let regrown = try await verify()
        guard regrown == initialMemory else { throw Failure.check("guest capacity not restored") }
        try await resourceSnapshot("regrown-\(cycle)")
        observations.append([
          "cycle": cycle, "activeQueryMemoryBytes": observed,
          "activeAfterUnplugMemoryBytes": memoryAfterUnplug,
          "initialGuestBytes": initialMemory, "shrunkGuestBytes": shrunk,
          "regrownGuestBytes": regrown, "integrity": expected, "loadResult": loadResult,
        ])
      }
      _ = try await verify(quit: true)
      input.finish()
      guard try await canary!.wait(timeoutInSeconds: 5).exitCode == 0 else {
        throw Failure.check("canary exit")
      }
      try await canary!.delete()
      canary = nil
    } catch { primary = String(describing: error) }
    input.finish()
    if let canary {
      let failures = await Task { @concurrent in
        var errors: [String] = []
        do { try await canary.kill(.kill) } catch { errors.append("canary kill \(error)") }
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
    let result: [String: Any] = [
      "primaryError": primary, "cleanupErrors": cleanup,
      "cycles": observations, "canaryTranscript": transcript, "commands": commands,
      "canaryBytes": 64 << 20, "rows": 400000, "resources": resources,
    ]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appending(path: "workload.json"), options: .withoutOverwriting)
    guard primary.isEmpty, cleanup.isEmpty, observations.count == 2 else {
      throw Failure.check(primary)
    }
    return true
  }
}
