import Containerization
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
    probe: URL
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
    do {
      let agent = try await vm.dialAgent()
      do {
        let handle = try FileHandle(forReadingFrom: probe)
        defer { try? handle.close() }
        var written = 0
        while let bytes = try handle.read(upToCount: 65536), !bytes.isEmpty {
          guard bytes.count <= (8 << 20) - written else { throw Failure.check("probe size") }
          try await agent.writeFile(
            path: "/run/container/swiftos-native/rootfs/lab/canary", data: bytes,
            flags: .init(create: written == 0, append: written != 0), mode: 0o700)
          written += bytes.count
        }
        guard written > 0 else { throw Failure.check("probe empty") }
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
      _ = try await sql(
        container,
        query:
          "CREATE TABLE default.ram_lab (id UInt64, payload String) ENGINE=MergeTree ORDER BY id")
      for batch in 0..<4 {
        _ = try await sql(
          container,
          query:
            "INSERT INTO default.ram_lab SELECT number + \(batch * 100000), repeat(hex(cityHash64(number + \(batch * 100000))), 8) FROM numbers(100000)"
        )
      }
      let integrity =
        "SELECT count(), sum(id), sum(cityHash64(payload)), sum(length(payload)) FROM default.ram_lab WHERE id < 400000 LIMIT 1"
      let expected = "400000\t79999800000\t9410121038903895322\t51176128"
      let baseline = try await sql(container, query: integrity)
      guard baseline == expected else { throw Failure.check("initial integrity " + baseline) }
      canary = try await container.exec("canary") { config in
        config.arguments = ["/lab/canary"]
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
      guard initialFields.count == 3, initialFields[0] == "CANARY_READY",
        let initialMemory = UInt64(initialFields[1])
      else { throw Failure.check(first) }
      var sequence = 0
      func verify(quit: Bool = false) async throws -> UInt64 {
        sequence += 1
        try input.send(Data("\(quit ? "QUIT" : "VERIFY") \(sequence)\n".utf8))
        let text = try await line()
        transcript.append(text)
        let fields = text.split(separator: " ")
        guard fields.count == 4, fields[0] == "CANARY_OK", Int(fields[1]) == sequence,
          let total = UInt64(fields[2])
        else { throw Failure.check(text) }
        return total
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
      for cycle in 1...2 {
        let queryID = "swiftos-load-\(cycle)"
        let query =
          "SELECT sum(length(payload) + sleepEachRow(0.000005)) FROM (SELECT id, any(payload) AS payload FROM default.ram_lab WHERE id < 400000 GROUP BY id) LIMIT 1"
        activeLoad = Task { try await sql(container, query: query, queryID: queryID) }
        var observed: UInt64 = 0
        for _ in 0..<24 {
          let state = try await sql(
            container,
            query:
              "SELECT count(), sum(memory_usage) FROM system.processes WHERE query_id = '\(queryID)' LIMIT 1"
          ).split(separator: "\t")
          guard state.count == 2, let memory = UInt64(state[1]) else {
            throw Failure.check("load observation")
          }
          if state[0] == "1", memory >= 16 << 20 {
            observed = memory
            break
          }
          try await Task.sleep(for: .milliseconds(25))
        }
        guard observed >= 16 << 20 else { throw Failure.check("active query not observed") }
        try vm.requestMemory(bytes: 0)
        try await waitMemory(vm, bytes: 0)
        let shrunk = try await verify()
        let stillRunning = try await sql(
          container,
          query:
            "SELECT count(), sum(memory_usage) FROM system.processes WHERE query_id = '\(queryID)' LIMIT 1"
        ).split(separator: "\t")
        guard stillRunning.count == 2, stillRunning[0] == "1",
          let memoryAfterUnplug = UInt64(stillRunning[1]), memoryAfterUnplug >= 16 << 20
        else { throw Failure.check("query ended before unplug completed") }
        try await resourceSnapshot("shrunk-\(cycle)")
        guard initialMemory >= shrunk, initialMemory - shrunk == 128 << 20 else {
          throw Failure.check("guest capacity not reduced")
        }
        let loadResult = try await activeLoad!.value
        activeLoad = nil
        guard loadResult == "51176128" else { throw Failure.check("load aggregate " + loadResult) }
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
      _ = await activeLoad.result
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
