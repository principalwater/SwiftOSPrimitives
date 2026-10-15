import AppleContainerMemory
import BoundedMemory
import Containerization
import ContainerizationExtras
import CryptoKit
import Darwin
import Foundation
import NIOPosix
import PageMemory
import Synchronization
@preconcurrency import Virtualization

private let mib: UInt64 = 1 << 20
private let initDigest = "sha256:4c1836052eafcbc944c403fb23ded06562962d2402c9dcc651495a32300614df"
private let workloadDigest =
  "sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1"

final class LabVMGuard: VZInstanceExtension {
  private struct State {
    weak var instance: VZVirtualMachineInstance?
    var resources: (cpus: Int, memory: UInt64, networkDevices: Int)?
  }
  private let state = Mutex(State())
  private let expectedMemoryBytes: UInt64
  init(expectedMemoryBytes: UInt64 = 512 * mib) {
    self.expectedMemoryBytes = expectedMemoryBytes
  }
  var instance: VZVirtualMachineInstance? { state.withLock { $0.instance } }
  var resources: (cpus: Int, memory: UInt64, networkDevices: Int)? {
    state.withLock { $0.resources }
  }
  func configureVZ(
    _ config: inout VZVirtualMachineConfiguration, allocator: any AddressAllocator<Character>,
    storageDeviceCount: Int, mountsByID: [String: [Containerization.Mount]]
  ) throws {
    guard config.networkDevices.isEmpty, config.cpuCount == 1, config.memorySize == expectedMemoryBytes else {
      throw LabFailure.invariant
    }
    try state.withLock { state in
      guard state.resources == nil else { throw LabFailure.invariant }
      state.resources = (config.cpuCount, config.memorySize, config.networkDevices.count)
    }
  }
  func didCreate(_ instance: VZVirtualMachineInstance) throws {
    try state.withLock { state in
      guard state.instance == nil, state.resources != nil else { throw LabFailure.invariant }
      state.instance = instance
    }
  }
}

struct LabManager: VirtualMachineManager {
  let base: VZVirtualMachineManager
  let device: ContainerBalloonDevice?
  let share: LabVMGuard
  func create(config: some VMCreationConfig) async throws -> any VirtualMachineInstance {
    var configuration = config.configuration
    configuration.extensions.append(share)
    if let device {
      return try await BalloonVirtualMachineManager(base: base, device: device)
        .create(config: StandardVMConfig(configuration: configuration))
    }
    return try base.create(config: StandardVMConfig(configuration: configuration))
  }
}

@main @MainActor struct ContainerMemoryLab {
  static func main() async {
    do {
      let args = Array(CommandLine.arguments.dropFirst())
      if args.count == 2, args[0] == "prepare" {
        try await prepare(URL(filePath: args[1]))
      } else if args.count == 2, args[0] == "prepare-clickhouse" {
        try await ClickHouseLab.prepare(URL(filePath: args[1]))
      } else if args.count == 7, args[0] == "clickhouse", ["held", "adaptive"].contains(args[6]) {
        try await ClickHouseLab.run(
          prepared: URL(filePath: args[1]), initfs: URL(filePath: args[2]),
          kernel: URL(filePath: args[3]), probeDirectory: URL(filePath: args[4]),
          output: URL(filePath: args[5]), adaptive: args[6] == "adaptive")
      } else if args.count == 6, args[0] == "run",
        ["policy", "held", "absent", "ignored", "cancel", "paused", "paused-cancel"].contains(args[5])
      {
        try await run(
          prepared: URL(filePath: args[1]), kernel: URL(filePath: args[2]),
          share: URL(filePath: args[3]), output: URL(filePath: args[4]), mode: args[5])
      } else {
        throw LabFailure.arguments
      }
    } catch {
      print("CONTAINER_MEMORY_LAB_FAIL \(error)")
      exit(1)
    }
  }
  static func fresh(_ path: URL) throws {
    guard path.path.hasPrefix("/"), path.standardizedFileURL == path,
      path.resolvingSymlinksInPath() == path,
      !FileManager.default.fileExists(atPath: path.path)
    else { throw LabFailure.arguments }
    try FileManager.default.createDirectory(
      at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  }
  private static func prepare(_ root: URL) async throws {
    try fresh(root)
    let store = try ImageStore(path: root.appending(path: "images"))
    let initImage = try await store.get(
      reference: "ghcr.io/apple/containerization/vminit:0.47.0", pull: true)
    guard initImage.digest == initDigest else { throw LabFailure.invariant }
    let initial = InitImage(image: initImage)
    _ = try await initial.initBlock(at: root.appending(path: "initfs.ext4"), for: .linuxArm)
    let image = try await store.get(reference: "docker.io/library/alpine:3.22.1", pull: true)
    guard image.digest == workloadDigest else { throw LabFailure.invariant }
    _ = try await EXT4Unpacker(capacityInBytes: 256 * mib).unpack(
      image, for: .current, at: root.appending(path: "rootfs.ext4"))
    let provenance = [
      "initReference": initImage.reference, "initDigest": initImage.digest,
      "workloadReference": image.reference, "workloadDigest": image.digest,
    ]
    try JSONEncoder().encode(provenance).write(
      to: root.appending(path: "images.json"), options: .withoutOverwriting)
    try Data("Apple Container1.5.0 / Containerization0.47.0\n".utf8)
      .write(to: root.appending(path: "PREPARED"), options: .withoutOverwriting)
    print("CONTAINER_MEMORY_PREPARED")
  }
  static func scanInput(_ path: URL, maximumBytes: Int, chunk: (Data) -> Void) throws {
    guard path.path.hasPrefix("/"), path.standardizedFileURL == path,
      path.resolvingSymlinksInPath() == path
    else { throw LabFailure.arguments }
    let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard fd >= 0 else { throw LabFailure.arguments }
    let input = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    do {
      // Large image hashes must not populate the host's file cache.
      guard maximumBytes <= 64 << 20 || fcntl(fd, F_NOCACHE, 1) == 0 else {
        throw LabFailure.arguments
      }
      var info = stat()
      guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
        info.st_size > 0, info.st_size <= maximumBytes
      else { throw LabFailure.arguments }
      var total = 0
      while let data = try autoreleasepool(invoking: { try input.read(upToCount: 65536) }),
        !data.isEmpty {
        guard data.count <= maximumBytes - total else { throw LabFailure.arguments }
        total += data.count
        chunk(data)
      }
      guard total == info.st_size else { throw LabFailure.arguments }
      try input.close()
    } catch {
      try? input.close()
      throw error
    }
  }
  static func digest(_ path: URL, maximumBytes: Int = 64 << 20) throws -> String {
    var hash = SHA256()
    try scanInput(path, maximumBytes: maximumBytes) { hash.update(data: $0) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
  static func nativeStopped(_ instance: VZVirtualMachineInstance?) async -> Bool {
    guard let instance else { return false }
    return await withCheckedContinuation { reply in
      instance.vmQueue.async {
        reply.resume(returning: instance.vzVirtualMachine.state == .stopped)
      }
    }
  }
  private static func run(
    prepared: URL, kernel: URL, share directory: URL, output: URL, mode: String
  ) async throws {
    let probeFile = directory.appending(path: "probe")
    var marker = Data()
    try scanInput(prepared.appending(path: "PREPARED"), maximumBytes: 128) { marker.append($0) }
    guard output != directory, !output.path.hasPrefix(directory.path + "/"),
      directory.resolvingSymlinksInPath() == directory,
      probeFile.resolvingSymlinksInPath() == probeFile,
      try probeFile.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
      marker == Data("Apple Container1.5.0 / Containerization0.47.0\n".utf8),
      try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["probe"]
    else { throw LabFailure.arguments }
    let probeDigest = try digest(probeFile)
    let kernelDigest = try digest(kernel)
    guard kernelDigest == "fb2cfb79eb1ae19447a85d75682d7fa5cfec97e24beb2609a492b806e8072c8d"
    else { throw LabFailure.arguments }
    var metadata = Data()
    try scanInput(prepared.appending(path: "images.json"), maximumBytes: 65536) {
      metadata.append($0)
    }
    let images = try JSONDecoder().decode([String: String].self, from: metadata)
    guard images["initDigest"] == initDigest, images["workloadDigest"] == workloadDigest else {
      throw LabFailure.arguments
    }
    try fresh(output)
    let rootfs = output.appending(path: "rootfs.ext4")
    try FileManager.default.copyItem(at: prepared.appending(path: "rootfs.ext4"), to: rootfs)
    let hostBefore = try ProcessMemorySnapshot.capture()
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    let device = mode == "absent" ? nil : ContainerBalloonDevice(minimumResidentBytes: 256 * mib)
    let share = LabVMGuard()
    var boot = Kernel(path: kernel, platform: .linuxArm)
    if mode == "ignored" {
      boot.commandLine.kernelArgs.append("initcall_blacklist=virtio_balloon_driver_init")
    }
    let base = VZVirtualMachineManager(
      kernel: boot,
      initialFilesystem: .block(
        format: "ext4", source: prepared.appending(path: "initfs.ext4").path,
        destination: "/", options: ["ro"]), group: group)
    let manager = LabManager(base: base, device: device, share: share)
    let input = CommandInput()
    let capture = ProbeOutput()
    let began = ContinuousClock.now
    let workload = ProbeChannel(input: input, output: capture, began: began)
    let container = try LinuxContainer(
      "swiftos-memory-lab",
      rootfs: .block(
        format: "ext4", source: rootfs.path, destination: "/"),
      vmm: manager, vm: .init(cpus: 1, memoryInBytes: 512 * mib)
    ) { config in
      config.cpus = 1
      config.memoryInBytes = 128 * mib
      config.interfaces = []
      config.process.arguments = ["/probe/probe", "--workload"]
      config.process.stdin = input
      config.process.stdout = capture
      config.process.stderr = capture
      config.process.noNewPrivileges = true
      config.mounts.append(.share(source: directory.path, destination: "/probe", options: ["ro"]))
      config.bootLog = .file(path: output.appending(path: "boot.log"), append: false)
    }
    var diagnosticProcess: LinuxProcess?
    var diagnostic: ProbeChannel?
    var ownedInstance: VZVirtualMachineInstance?
    var primary: (any Error)?
    var cleanup: (any Error)?
    var requests: [[String: UInt64]] = []
    var observations: [[String: UInt64]] = []
    var expectedTimeout = false
    var cancelledAfterCompletion = false
    var injectedFailure = false
    var forced = false
    var forceOutcome = ""
    var forceError = ""
    var cleanupCompleted = false
    var cleanupStages: [String] = []
    var cleanupFailures: [String] = []
    var nioShutdownSucceeded = false
    do {
      try await container.create()
      ownedInstance = share.instance
      guard ownedInstance != nil else { throw LabFailure.invariant }
      try await container.start()
      try await workload.ready(expectedDriver: "workload")
      try await workload.verifyWorkloadLimitsAndMount()
      guard let instance = share.instance, instance.state == .running else {
        throw LabFailure.invariant
      }
      if let device {
        guard device.virtualMachineInstance === instance else { throw LabFailure.invariant }
      }
      let diagnosticInput = CommandInput()
      let diagnosticOutput = ProbeOutput()
      let probe = ProbeChannel(input: diagnosticInput, output: diagnosticOutput, began: began)
      diagnostic = probe
      // PCI config beyond64 bytes needs SYS_ADMIN; only this trusted diagnostic exec gets it.
      let process = try await container.exec("swiftos-memory-agent") { config in
        config.arguments = ["/probe/probe", "--agent"]
        config.stdin = diagnosticInput
        config.stdout = diagnosticOutput
        config.stderr = diagnosticOutput
        config.noNewPrivileges = true
        config.capabilities = .init(
          capabilities: LinuxCapabilities.defaultOCICapabilities.effective + [.sysRawio, .sysAdmin])
      }
      diagnosticProcess = process
      try await process.start()
      let driver = mode == "absent" ? "none" : mode == "ignored" ? "unbound" : "bound:"
      try await probe.ready(expectedDriver: driver)
      guard
        let budget = BalloonBudget(
          installedBytes: 512 * mib, minimumResidentBytes: 256 * mib,
          granuleBytes: mib, maximumStepBytes: 64 * mib),
        var controller = BalloonController(
          budget: budget, epoch: 1, guestReserveBytes: 128 * mib, hysteresisBytes: 16 * mib,
          maximumObservationAgeNanoseconds: 3_000_000_000,
          cooldownNanoseconds: 100_000_000, completionTimeoutNanoseconds: 5_000_000_000)
      else { throw LabFailure.invariant }
      defer { controller.retire() }
      let warm = try await workload.observe("T")
      guard warm.residentPages == 22528 else { throw LabFailure.invariant }
      var shrinks = 0
      var grows = 0
      phases: for phase in 0..<3 {
        let previousShrinks = shrinks
        let previousGrows = grows
        let memory = try await workload.observe(phase == 1 ? "T" : "E")
        guard memory.residentPages == (phase == 1 ? 22528 : 0) else { throw LabFailure.invariant }
        var settled = false
        var idle = 0
        for _ in 0..<120 {
          try Task.checkCancellation()
          let observation = try await probe.observe("S")
          observations.append([
            "sequence": observation.sequence, "capturedAt": observation.capturedAtNanoseconds,
            "returnedAt": probe.now, "available": observation.available,
            "requestedPFNs": UInt64(observation.requestedPFNs),
            "actualPFNs": UInt64(observation.actualPFNs),
          ])
          if mode == "held" || mode == "absent" {
            guard observation.actualPFNs == (mode == "absent" ? UInt32.max : 0) else {
              throw LabFailure.invariant
            }
            settled = true
            break
          }
          do {
            try controller.checkDeadline(nowNanoseconds: probe.now)
          } catch BalloonController.Failure.completionTimedOut where mode == "ignored" {
            let heartbeat = try await probe.observe("S")
            guard heartbeat.actualPFNs == 0, heartbeat.requestedPFNs > 0 else {
              throw LabFailure.invariant
            }
            expectedTimeout = true
            break
          }
          let actual = UInt64(observation.actualPFNs) * 4096
          let requested = UInt64(observation.requestedPFNs) * 4096
          guard actual <= budget.installedBytes, requested <= budget.installedBytes else {
            throw LabFailure.invariant
          }
          let sample = BalloonController.Observation(
            epoch: 1, sequence: observation.sequence,
            capturedAtNanoseconds: observation.capturedAtNanoseconds,
            actualResidentBytes: budget.installedBytes - actual,
            requestedResidentBytes: budget.installedBytes - requested,
            guestAvailableBytes: observation.available,
            hostResidentLimitBytes: budget.installedBytes,
            hostUnderPressure: false, guestUnderPressure: false)
          if let request = try controller.observe(sample, nowNanoseconds: probe.now) {
            guard let device else { throw LabFailure.invariant }
            _ = try await device.request(request.targetResidentBytes)
            let appliedAt = probe.now
            try controller.didApply(
              request, afterObservationSequence: probe.sequence, atNanoseconds: appliedAt)
            requests.append([
              "initial": request.initialResidentBytes, "target": request.targetResidentBytes,
              "sequence": request.sequence, "available": observation.available,
              "issuedAt": request.issuedAtNanoseconds, "deliveredAt": appliedAt,
            ])
            if request.targetResidentBytes < request.initialResidentBytes {
              shrinks += 1
            } else {
              grows += 1
            }
            idle = 0
          } else if controller.pendingRequest == nil {
            if (mode == "paused" || mode == "paused-cancel"), shrinks > 0 {
              try await instance.pause()
              let paused = await withCheckedContinuation { reply in
                instance.vmQueue.async {
                  reply.resume(returning: instance.vzVirtualMachine.state == .paused)
                }
              }
              guard paused else { throw LabFailure.invariant }
              injectedFailure = true
              if mode == "paused-cancel" { withUnsafeCurrentTask { $0?.cancel() } }
              break phases
            }
            if mode == "cancel", shrinks > 0 {
              cancelledAfterCompletion = true
              withUnsafeCurrentTask { $0?.cancel() }
              throw CancellationError()
            }
            idle += 1
            // MemAvailable publication can lag workload faults; require this phase's real reaction.
            let phaseReacted = phase == 1 ? grows > previousGrows : shrinks > previousShrinks
            if idle >= 2, mode != "policy" || phaseReacted {
              settled = true
              break
            }
          } else {
            idle = 0
          }
          try await Task.sleep(for: .milliseconds(100))
        }
        if expectedTimeout { break }
        guard settled, controller.pendingRequest == nil else { throw LabFailure.invariant }
      }
      if mode == "policy" { guard shrinks >= 2, grows >= 1 else { throw LabFailure.invariant } }
      if mode == "ignored" { guard expectedTimeout else { throw LabFailure.invariant } }
      // Normal fallthrough must not certify an unexercised cancellation control.
      if mode == "cancel" { throw LabFailure.invariant }
    } catch is CancellationError where mode == "cancel" && cancelledAfterCompletion {
      // Only the deliberate post-completion cancellation is an accepted control.
    } catch { primary = error }
    ownedInstance = ownedInstance ?? share.instance
    device?.retire()
    let process = diagnosticProcess
    let probe = diagnostic
    let cleanupBegan = ContinuousClock.now
    let watchdog = Task { @MainActor in
      do { try await Task.sleep(for: injectedFailure ? .seconds(1) : .seconds(10)) }
      catch { return }
      guard !cleanupCompleted, let device else { return }
      forced = true
      do {
        forceOutcome = String(describing: try await device.retireAndStop())
        // Native stopped state makes every remaining response impossible.
        probe?.close()
        workload.close()
      }
      catch { forceError = String(describing: error) }
    }
    let stopping = Task { @MainActor in
      var first: (any Error)?
      if let probe, let process {
        var quitClean = true
        do { try await probe.quit() } catch {
          first = error
          cleanupFailures.append("diagnostic quit: \(error)")
          quitClean = false
        }
        probe.close()
        if !quitClean {
          do { try await process.kill(.kill) } catch {
            first = first ?? error
            cleanupFailures.append("diagnostic kill: \(error)")
          }
        }
        do {
          let status = try await process.wait(timeoutInSeconds: 3)
          guard status.exitCode == 0 else { throw LabFailure.invariant }
        } catch {
          first = first ?? error
          cleanupFailures.append("diagnostic wait: \(error)")
        }
        do { try await process.delete() } catch {
          first = first ?? error
          cleanupFailures.append("diagnostic delete: \(error)")
        }
        cleanupStages.append("diagnostic-ended")
      } else { probe?.close() }
      do {
        try await workload.quit()
        let status = try await container.wait()
        guard status.exitCode == 0 else { throw LabFailure.invariant }
      } catch {
        first = first ?? error
        cleanupFailures.append("workload: \(error)")
      }
      workload.close()
      cleanupStages.append("workload-ended")
      do { try await container.stop() } catch {
        first = first ?? error
        cleanupFailures.append("runtime: \(error)")
      }
      if let instance = ownedInstance, instance.state == .running {
        do { try await instance.stop() } catch {
          first = first ?? error
          cleanupFailures.append("VM: \(error)")
        }
      }
      cleanupStages.append("runtime-stop-ended")
      do {
        try await group.shutdownGracefully()
        nioShutdownSucceeded = true
      } catch {
        first = first ?? error
        cleanupFailures.append("NIO: \(error)")
      }
      cleanupStages.append("nio-shutdown-ended")
      cleanupCompleted = true
      return first
    }
    cleanup = await stopping.value
    watchdog.cancel()
    await watchdog.value
    let cleanupElapsed = cleanupBegan.duration(to: .now).components
    var stopRetry = ""
    var lateSetterRefused = false
    if forced, let device, forceError.isEmpty {
      stopRetry = String(describing: try await device.retireAndStop())
      do { _ = try await device.request(512 * mib) }
      catch ContainerBalloonDevice.Failure.retired { lateSetterRefused = true }
    }
    let hostAfter = try ProcessMemorySnapshot.capture()
    let stopped = await nativeStopped(ownedInstance)
    let finalProbeDigest = try digest(probeFile)
    let finalKernelDigest = try digest(kernel)
    guard probeDigest == finalProbeDigest, kernelDigest == finalKernelDigest,
      try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["probe"]
    else { throw LabFailure.invariant }
    let result: [String: Any] = [
      "containerRelease": "1.5.0", "containerizationRelease": "0.47.0", "mode": mode,
      "requests": requests, "observations": observations, "workloadTranscript": workload.transcript,
      "agentTranscript": probe?.transcript ?? [], "stopped": stopped,
      "primaryError": primary.map { String(describing: $0) } ?? "",
      "cleanupError": cleanup.map { String(describing: $0) } ?? "",
      "injectedFailure": injectedFailure, "forced": forced,
      "callerCancelledAtCleanup": Task.isCancelled,
      "forceOutcome": forceOutcome, "forceError": forceError,
      "stopRetry": stopRetry, "lateSetterRefused": lateSetterRefused,
      "cleanupJoined": cleanupCompleted, "cleanupStages": cleanupStages,
      "cleanupFailures": cleanupFailures, "nioShutdownSucceeded": nioShutdownSucceeded,
      "cleanupElapsedNanoseconds": UInt64(cleanupElapsed.seconds) * 1_000_000_000
        + UInt64(cleanupElapsed.attoseconds / 1_000_000_000),
      "upstreamInternalTaskClosure": forced ? "UNQUALIFIED: TimeSyncer public cleanup gap" : "normal",
      "expectedTimeout": expectedTimeout, "cancelledAfterCompletion": cancelledAfterCompletion,
      "networkDevices": share.resources?.networkDevices ?? -1,
      "vmCPUs": share.resources?.cpus ?? -1, "vmInstalledBytes": 512 * mib,
      "observedVMInstalledBytes": share.resources?.memory ?? 0,
      "probeSHA256": probeDigest, "kernelSHA256": kernelDigest, "images": images,
      "containerLimitBytes": 128 * mib,
      "diagnosticPrivilege":
        "CAP_SYS_RAWIO/SYS_ADMIN diagnostic exec; trusted synthetic container only",
      "ociRuntime": "release vmexec; opt-in runc/seccomp not enabled",
      "physicalReleasedBytes": NSNull(),
      "hostControllerRSSBefore": hostBefore.residentBytes,
      "hostControllerRSSAfter": hostAfter.residentBytes,
      "scope":
        "release Containerization/LinuxContainer core runtime; stock CLI not patched or installed",
      "hostCounterScope": "controller process only; exact VZ helper backing authority unavailable",
    ]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appending(path: "result.json"), options: .withoutOverwriting)
    guard primary == nil, stopped, cleanupCompleted, nioShutdownSucceeded, forceError.isEmpty else {
      throw LabFailure.invariant
    }
    if mode == "paused" || mode == "paused-cancel" {
      guard injectedFailure, forced, forceOutcome == "stopped", stopRetry == "alreadyStopped",
        lateSetterRefused else { throw LabFailure.invariant }
    } else {
      guard !forced, cleanup == nil else { throw LabFailure.invariant }
    }
    print("CONTAINER_MEMORY_LAB_PASS \(mode)")
  }
}
