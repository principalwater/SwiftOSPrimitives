import Containerization
import Darwin
import Foundation
import NIOPosix
import NativeLinuxVMM

/// Finite actual owner qualification; no workload, NIC, or product-autonomy admission.
enum MonitorOwnerCheck {
  enum Failure: Error { case check(String) }
  enum Scenario: String { case normal, cancel, deadline, digest, expiredShutdown }

  private static func record(_ snapshot: NativeMemoryService.Snapshot) -> [String: Any] {
    [
      "phase": snapshot.phase.rawValue, "stage": snapshot.stage,
      "pid": snapshot.pid.map { $0 as Any } ?? NSNull(),
      "waited": snapshot.waited, "deleted": snapshot.deleted,
      "rootUnmounted": snapshot.rootUnmounted, "pendingOperations": snapshot.pendingOperations,
      "memoryBytes": snapshot.memoryBytes.map { $0 as Any } ?? NSNull(),
      "diagnostics": snapshot.diagnostics, "primaryError": snapshot.primaryError,
      "cleanupErrors": snapshot.cleanupErrors,
    ]
  }

  static func run(args: [String]) async throws {
    guard
      let scenario = Scenario(
        rawValue: ProcessInfo.processInfo.environment["SWIFTOS_LAB_MONITOR_SCENARIO"] ?? "normal"),
      let sha = ProcessInfo.processInfo.environment["SWIFTOS_MONITOR_SHA256"]
    else { throw Failure.check("scenario/artifact manifest") }
    let output = URL(filePath: args[3])
    try FileManager.default.createDirectory(
      at: output, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let directory = open(args[7], O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard directory >= 0 else { throw Failure.check("boot directory \(errno)") }
    defer { Darwin.close(directory) }
    let resources = try NativeBootResources(directoryDescriptor: directory)
    let geometry = try NativeMemoryGeometry(bootBytes: 512 << 20, dynamicBytes: 2560 << 20)
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    let manager = NativeVirtualMachineManager(
      resources: resources, group: group, memoryGeometry: geometry, executionPolicy: .qualification,
      classicBallooning: true)
    var agent: Vminitd?
    var owner: NativeMemoryService?
    var primary = ""
    var cleanup: [String] = []
    var expectedFailure = ""
    var cancellationStage = ""
    var beforeStop: [String: Any] = [:]
    var observations: [UInt64] = []
    var secondOwnerRefused = false
    do {
      let instance = try await manager.create(
        config: StandardVMConfig(
          configuration: .init(
            cpus: 2, memoryInBytes: geometry.maximumBytes, interfaces: [],
            mountsByID: [
              "owner-check": [
                .block(
                  format: "ext4", source: resources.mountSource, destination: "/")
              ]
            ])))
      let bootDeadline = ContinuousClock.now.advanced(by: .seconds(21))
      try await instance.start()
      guard let vm = manager.instance else { throw Failure.check("native instance") }
      let client = try await vm.dialAgent()
      agent = client
      try await client.standardSetup()
      let descriptor = open(args[5], O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
      guard descriptor >= 0 else { throw Failure.check("program open \(errno)") }
      let service: NativeMemoryService
      do {
        service = try NativeMemoryService(
          vm: vm, agent: client, programDescriptor: descriptor,
          sha256: scenario == .digest ? String(repeating: "0", count: 64) : sha)
      } catch {
        Darwin.close(descriptor)
        throw error
      }
      guard Darwin.close(descriptor) == 0 else { throw Failure.check("borrow close") }
      owner = service
      if scenario == .normal || scenario == .expiredShutdown {
        try await service.start(until: bootDeadline)
        guard service.snapshot.phase == .live, service.snapshot.memoryBytes != nil,
          service.snapshot.pendingOperations == 0
        else { throw Failure.check("live ownership") }
        let session = try service.session
        for refresh in [false, true] {
          guard
            let sample = try await session.observeIfIdle(
              deadline: .now.advanced(by: .seconds(5)), refreshStatistics: refresh)
          else { throw Failure.check("missing observation") }
          observations.append(sample.sequence)
        }
        do {
          try await service.start(until: bootDeadline)
          throw Failure.check("duplicate start accepted")
        } catch NativeControlFailure.ownership {}
        guard service.snapshot.phase == .live else {
          throw Failure.check("duplicate poisoned owner")
        }
        if scenario == .expiredShutdown {
          do {
            try await service.shutdown(until: .now.advanced(by: .seconds(-1)))
            throw Failure.check("expired shutdown accepted")
          } catch NativeControlFailure.drainTimedOut { expectedFailure = "drainTimedOut" }
          guard service.snapshot.phase == .failed else {
            throw Failure.check("expired shutdown left live admission")
          }
          do {
            try await service.shutdown(until: .now.advanced(by: .seconds(8)))
            throw Failure.check("shutdown renewed an expired budget")
          } catch NativeControlFailure.ownership {}
        } else {
          // There is no governor in this finite mode; its observation tasks above have joined.
          try await service.shutdown(until: .now.advanced(by: .seconds(8)))
          let stopped = service.snapshot
          guard stopped.phase == .stopped, stopped.waited, stopped.deleted, stopped.rootUnmounted,
            stopped.primaryError.isEmpty, stopped.cleanupErrors.isEmpty,
            stopped.pendingOperations == 0
          else { throw Failure.check("graceful ownership") }
          try await service.shutdown(until: .now.advanced(by: .seconds(8)))
          let nextDescriptor = open(args[5], O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
          guard nextDescriptor >= 0 else { throw Failure.check("second owner artifact") }
          let candidate: NativeMemoryService
          do {
            candidate = try NativeMemoryService(
              vm: vm, agent: client, programDescriptor: nextDescriptor, sha256: sha)
          } catch {
            Darwin.close(nextDescriptor)
            throw error
          }
          guard Darwin.close(nextDescriptor) == 0 else {
            throw Failure.check("second borrow close")
          }
          defer { candidate.abort() }
          do {
            try await candidate.start(until: .now.advanced(by: .seconds(1)))
            throw Failure.check("second owner admitted within same VM boot")
          } catch NativeControlFailure.ownership { secondOwnerRefused = true }
        }
      } else {
        let deadline =
          scenario == .deadline
          ? min(bootDeadline, .now.advanced(by: .milliseconds(10))) : bootDeadline
        let startup = Task { try await service.start(until: deadline) }
        if scenario == .cancel {
          while service.snapshot.stage != "upload" {
            guard service.snapshot.phase != .live, ContinuousClock.now < bootDeadline,
              service.snapshot.phase != .failed
            else {
              startup.cancel()
              _ = await startup.result
              throw Failure.check("cancel stage not reached")
            }
            try await Task.sleep(for: .milliseconds(1))
          }
          cancellationStage = service.snapshot.stage
          startup.cancel()
        }
        let result = await startup.result
        switch result {
        case .success: throw Failure.check("expected startup refusal")
        case .failure(let error):
          if scenario == .cancel {
            guard error is CancellationError else { throw error }
          } else if scenario == .deadline {
            guard error as? NativeControlFailure == .lifetimeExpired else { throw error }
          } else {
            guard error as? NativeControlFailure == .ownership else { throw error }
          }
          expectedFailure = String(describing: error)
        }
        guard service.snapshot.phase == .failed else { throw Failure.check("failed admission") }
        do {
          _ = try service.session
          throw Failure.check("escaped failed session")
        } catch NativeControlFailure.ownership {}
      }
      beforeStop = record(service.snapshot)
    } catch { primary = String(describing: error) }
    owner?.abort()
    if let vm = manager.instance {
      do { try await vm.stop() } catch { cleanup.append("native-stop \(error)") }
      if let owner {
        do { try await owner.joinAfterNativeStop(until: .now.advanced(by: .seconds(4))) } catch {
          cleanup.append("owner-join \(error)")
        }
      }
    }
    if let agent {
      do { try await agent.close() } catch { cleanup.append("agent-close \(error)") }
    }
    do { try await group.shutdownGracefully() } catch { cleanup.append("group-join \(error)") }
    if let native = manager.instance?.result {
      try native.write(to: output.appending(path: "native.json"), options: .withoutOverwriting)
    }
    let afterStop = owner.map { record($0.snapshot) } ?? [:]
    let retired = owner?.snapshot
    weak let releasedOwner = owner
    owner = nil
    let checked =
      primary.isEmpty && cleanup.isEmpty && retired?.phase == .retired
      && retired?.pendingOperations == 0 && retired?.cleanupErrors.isEmpty == true
      && releasedOwner == nil
      && (scenario == .normal
        ? observations == [1, 2] && secondOwnerRefused : !expectedFailure.isEmpty)
    let result: [String: Any] = [
      "checked": checked, "scenario": scenario.rawValue, "primaryError": primary,
      "cleanupErrors": cleanup, "beforeStop": beforeStop, "afterStop": afterStop,
      "expectedFailure": expectedFailure, "cancellationStage": cancellationStage,
      "secondOwnerRefused": secondOwnerRefused, "ownerARCReleased": releasedOwner == nil,
      "observations": observations, "physicalReleasedBytes": NSNull(),
      "scope": "Actual bounded service owner; trusted isolated guest, not product autonomy",
    ]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appending(path: "result.json"), options: .withoutOverwriting)
    guard checked else { throw Failure.check(primary + cleanup.joined(separator: "; ")) }
    print("MONITOR_OWNER_CHECK_PASS")
  }
}
