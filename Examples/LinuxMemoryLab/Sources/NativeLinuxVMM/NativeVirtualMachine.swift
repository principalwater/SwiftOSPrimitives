import Containerization
import Darwin
import Dispatch
import Foundation
import NIOPosix
import Synchronization

enum NativeFailure: Error {
  case unsupported, state, deadline, processBusy
  case stopped(String)
  case failedStart(String, String)
}
private enum NativeProcessLease {
  static let claimed = Mutex(false)
}

final class NativeControl: Sendable {
  enum Command: Sendable {
    case open(UInt32, Int32, UInt32)
    case cancel(UInt32)
  }
  struct State {
    var started = false
    var running = false
    var stop = false
    var ended = false
    var worker: UInt = 0
    var createFailed = false
    var joining = false
    var joined = false
    var joinComplete = false
    var joinError: Int32 = 0
    var pendingDials: Set<UInt32> = []
    var releaseAlias = false
    var refusals = 0
    var requested: UInt64 = 0
    var plugged: UInt64 = 0
    var memoryOwner: UInt64?
    var memoryGeneration: UInt64 = 0
    var memoryControlRetired = false
    var memoryQuarantineApplied = false
    var backingRetiredBytes: UInt64 = 0
    var recycledBackingBytes: UInt64 = 0
    var recycledResidentBytes: UInt64 = 0
    var recycledColdResidentBytes: UInt64 = 0
    var error = ""
    var result = Data()
    var commands: [Command] = []
    var listeners: [UInt32: VsockListener] = [:]
    var connected: [UInt32: Bool] = [:]
    var nextPort: UInt32 = 0x2000_0000
  }
  let state: Mutex<State>
  let memoryQuarantineRequested = Atomic(false)
  let kernel: URL?
  let initfs: URL?
  let rootfs: URL
  let console: URL?
  let resources: NativeBootResources?
  let held: Bool
  let alias: Bool
  let cpus: Int
  let geometry: NativeMemoryGeometry
  let freePageReporting: Bool
  let executionPolicy: NativeExecutionPolicy
  let networks: [IsolatedNetwork]

  init(
    kernel: URL?, initfs: URL?, rootfs: URL, console: URL?, held: Bool, alias: Bool, cpus: Int = 1,
    networks: [IsolatedNetwork] = [], geometry: NativeMemoryGeometry = .qualification,
    executionPolicy: NativeExecutionPolicy = .qualification, resources: NativeBootResources? = nil,
    freePageReporting: Bool = false
  ) {
    state = Mutex(State(requested: geometry.dynamicBytes))
    self.geometry = geometry
    self.freePageReporting = freePageReporting
    self.executionPolicy = executionPolicy
    self.kernel = kernel
    self.initfs = initfs
    self.rootfs = rootfs
    self.console = console
    self.resources = resources
    self.held = held
    self.alias = alias
    self.cpus = cpus
    self.networks = networks
  }
  func run() {
    let machine = LinuxMachine()
    machine.control = self
    machine.capacity = Int(geometry.bootBytes)
    machine.executionPolicy = executionPolicy
    machine.cpuCount = cpus
    machine.dynamicMemory = MemoryDevice(
      held: held, aliasControl: alias, geometry: geometry,
      coldProvisioning: freePageReporting && !held)
    if freePageReporting { machine.freePageReporting = FreePageReportingDevice() }
    let lease = NativeProcessLease.claimed.withLock { claimed -> Bool in
      guard !claimed else { return false }
      claimed = true
      return true
    }
    var primary = ""
    do {
      guard lease else { throw NativeFailure.processBusy }
      let kernelImage: Data
      if let resources {
        machine.disk = try BlockDevice(
          resources: resources, readOnly: true, executionPolicy: executionPolicy)
        machine.rootDisk = try BlockDevice(
          resources: resources, readOnly: false, interrupt: 37, executionPolicy: executionPolicy)
      } else {
        guard let initfs else { throw NativeFailure.unsupported }
        machine.disk = try BlockDevice(path: initfs.path, readOnly: true)
        machine.rootDisk = try BlockDevice(
          path: rootfs.path, interrupt: 37, executionPolicy: executionPolicy)
      }
      machine.vsock = VsockDevice(control: self)
      for network in networks { machine.networks.append(try NetworkDevice(network: network)) }
      if let resources {
        machine.consoleSink = FileHandle(
          fileDescriptor: try resources.duplicateConsole(), closeOnDealloc: true)
        kernelImage = try resources.takeKernel()
      } else {
        guard let kernel, let console else { throw NativeFailure.unsupported }
        let consoleDescriptor = open(
          console.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard consoleDescriptor >= 0 else {
          throw NativeFailure.stopped("console-open \(errno)")
        }
        machine.consoleSink = FileHandle(fileDescriptor: consoleDescriptor, closeOnDealloc: true)
        kernelImage = try NativeBootResources.kernelImage(at: kernel.path)
      }
      try machine.boot(kernel: consume kernelImage, initrd: Data())
    } catch { primary = String(describing: error) }
    machine.vsock?.close()
    var cleanup = machine.close()
    do { try machine.consoleSink?.close() } catch { cleanup.append("console-close \(error)") }
    let listeners = state.withLock { state in
      state.running = false
      for command in state.commands {
        if case .open(_, let descriptor, _) = command, Darwin.close(descriptor) != 0 {
          cleanup.append("pending-fd-close \(errno)")
        }
      }
      state.commands.removeAll()
      let listeners = Array(state.listeners.values)
      state.listeners.removeAll()
      return listeners
    }
    for listener in listeners {
      do { try listener.finish() } catch { cleanup.append("listener-finish \(error)") }
    }
    if !machine.created, cleanup.isEmpty {
      do { try resources?.retire() } catch { cleanup.append("boot-resources-retire \(error)") }
    }
    if lease, !machine.created, cleanup.isEmpty {
      NativeProcessLease.claimed.withLock { $0 = false }
    }
    let result: [String: Any] = [
      "primaryError": primary, "cleanupErrors": cleanup,
      "vmCreated": machine.wasCreated, "vmDestroyed": machine.wasCreated && !machine.created,
      "memoryObservations": machine.dynamicMemory?.observations ?? [],
      "memoryRefusals": machine.dynamicMemory?.refusals ?? [],
      "memoryObservationsTotal": machine.dynamicMemory?.observationsTotal ?? 0,
      "memoryRefusalsTotal": machine.dynamicMemory?.refusalsTotal ?? 0,
      "cumulativeBackingRetiredBytes": machine.dynamicMemory?.cumulativeBackingRetiredBytes ?? 0,
      "freePageReportingEnabled": freePageReporting,
      "freePageReports": machine.freePageReporting?.reports ?? 0,
      "freePageReportedBytes": machine.freePageReporting?.reportedBytes ?? 0,
      "freePageReportingObservations": machine.freePageReporting?.observations ?? [],
      "freePagePoison": machine.freePageReporting?.poison ?? 0,
      "recycledBackingBytes": machine.dynamicMemory?.recycledBackingBytes ?? 0,
      "recycledResidentBytes": machine.dynamicMemory?.recycledResidentBytes ?? 0,
      "recycledResidentBytesFromColdBacking": machine.dynamicMemory?.recycledColdResidentBytes ?? 0,
      "recyclingObservations": machine.dynamicMemory?.recyclingObservations ?? [],
      "recyclingObservationsTotal": machine.dynamicMemory?.recyclingObservationsTotal ?? 0,
      "networks": machine.networks.map {
        ["index": $0.index, "txPackets": $0.txPackets, "rxPackets": $0.rxPackets]
      },
      "cpus": machine.cpus?.statistics ?? [],
      "quiescentEpochs": machine.cpus?.epoch ?? 0,
      "maximumScheduledVCPUs": machine.cpus?.maximumScheduled ?? 0,
      "executionPolicy": executionPolicy.rawValue,
      "bootBytes": geometry.bootBytes, "dynamicCapacityBytes": geometry.dynamicBytes,
      "memoryControlGeneration": state.withLock { $0.memoryGeneration },
      "memoryControlRetired": state.withLock { $0.memoryControlRetired },
      "memoryQuarantineApplied": state.withLock { $0.memoryQuarantineApplied },
      "memoryQuarantine": machine.dynamicMemory?.quarantineRecord ?? [:],
      "diskAdmittedWriteBytes": machine.rootDisk?.written ?? 0,
      "consoleRetainedBytes": machine.console.count,
      "exits": machine.exits, "lastPC": String(machine.lastPC, radix: 16),
      "physicalReleasedBytes": NSNull(), "backend": "Swift HVF / Containerization0.47.0",
    ]
    let data =
      (try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]))
      ?? Data()
    state.withLock { state in
      state.error = primary + cleanup.joined(separator: ";")
      state.result = data
      state.ended = true
    }
  }

}

/// Private-NIC research backend for the current Apple Containerization API.
public final class NativeVirtualMachineManager: VirtualMachineManager {
  /// Legacy research path metadata; nil when resources were admitted by descriptor.
  public let kernel: URL?
  public let initfs: URL?
  public let console: URL?
  public let held: Bool
  public let aliasControl: Bool
  public let group: MultiThreadedEventLoopGroup
  public let memoryGeometry: NativeMemoryGeometry
  public let executionPolicy: NativeExecutionPolicy
  public let freePageReporting: Bool
  private let resources: NativeBootResources?
  private let owner = Mutex<NativeVirtualMachine?>(nil)

  public init(
    kernel: URL, initfs: URL, console: URL, held: Bool = false,
    aliasControl: Bool = false, group: MultiThreadedEventLoopGroup,
    memoryGeometry: NativeMemoryGeometry = .qualification,
    executionPolicy: NativeExecutionPolicy = .qualification, freePageReporting: Bool = false
  ) {
    self.memoryGeometry = memoryGeometry
    self.executionPolicy = executionPolicy
    self.freePageReporting = freePageReporting
    self.kernel = kernel
    self.initfs = initfs
    self.console = console
    self.held = held
    self.aliasControl = aliasControl
    self.group = group
    self.resources = nil
  }
  /// Uses only pinned resources. The root mount must use resources.mountSource verbatim.
  public init(
    resources: NativeBootResources, group: MultiThreadedEventLoopGroup,
    memoryGeometry: NativeMemoryGeometry = .qualification,
    executionPolicy: NativeExecutionPolicy = .sustained, freePageReporting: Bool = false
  ) {
    self.resources = resources
    kernel = nil
    initfs = nil
    console = nil
    held = false
    aliasControl = false
    self.group = group
    self.memoryGeometry = memoryGeometry
    self.executionPolicy = executionPolicy
    self.freePageReporting = freePageReporting
  }
  public var instance: NativeVirtualMachine? { owner.withLock { $0 } }
  public func create(config: some VMCreationConfig) async throws -> any VirtualMachineInstance {
    let config = config.configuration
    guard (1...4).contains(config.cpus), config.memoryInBytes == memoryGeometry.maximumBytes,
      config.interfaces.count <= 2, !config.nestedVirtualization, config.extensions.isEmpty,
      config.mountsByID.count == 1, let entry = config.mountsByID.first,
      let mount = entry.value.first, mount.type == "ext4", mount.destination == "/",
      case .virtioblk(let blockOptions) = mount.runtimeOptions, blockOptions.isEmpty
    else { throw NativeFailure.unsupported }
    guard resources.map({ mount.source == $0.mountSource }) ?? true else {
      throw NativeFailure.unsupported
    }
    let networks = try config.interfaces.enumerated().map { index, interface in
      guard let network = interface as? IsolatedNetwork, network.index == index else {
        throw NativeFailure.unsupported
      }
      return network
    }
    var attachments = [
      AttachedFilesystem(
        type: mount.type, source: "/dev/vdb", destination: mount.destination, options: mount.options
      )
    ]
    for additional in entry.value.dropFirst() {
      // Guest-only OCI mounts need no host attachment; host shares remain unsupported.
      guard case .any(let options) = additional.runtimeOptions, options.isEmpty,
        additional.destination != "/"
      else { throw NativeFailure.unsupported }
      attachments.append(
        .init(
          type: additional.type, source: additional.source,
          destination: additional.destination, options: additional.options))
    }
    let control = NativeControl(
      kernel: kernel, initfs: initfs, rootfs: URL(filePath: mount.source),
      console: console, held: held, alias: aliasControl, cpus: config.cpus, networks: networks,
      geometry: memoryGeometry, executionPolicy: executionPolicy, resources: resources,
      freePageReporting: freePageReporting)
    let machine = NativeVirtualMachine(
      control: control, group: group, id: entry.key,
      attachments: attachments)
    try owner.withLock {
      guard $0 == nil else { throw NativeFailure.state }
      try resources?.claim()
      $0 = machine
    }
    return machine
  }
}

public final class NativeVirtualMachine: VirtualMachineInstance {
  public typealias Agent = Vminitd
  let control: NativeControl
  let group: MultiThreadedEventLoopGroup
  public let mounts: [String: [AttachedFilesystem]]
  init(
    control: NativeControl, group: MultiThreadedEventLoopGroup, id: String,
    attachments: [AttachedFilesystem]
  ) {
    self.control = control
    self.group = group
    mounts = [id: attachments]
  }
  public var state: VirtualMachineInstanceState {
    control.state.withLock { $0.ended ? .stopped : ($0.running ? .running : .starting) }
  }
  public var result: Data {
    let snapshot = control.state.withLock { ($0.result, $0.joined, $0.joinError) }
    guard var result = (try? JSONSerialization.jsonObject(with: snapshot.0)) as? [String: Any]
    else { return snapshot.0 }
    result["workerJoined"] = snapshot.1
    result["joinError"] = snapshot.2
    return
      (try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]))
      ?? Data()
  }
  public var memoryGeometry: NativeMemoryGeometry { control.geometry }
  /// Cumulative native object retirement; resident pages are observations, not global free RAM.
  public var backingRecyclingStatus:
    (bytes: UInt64, residentBytes: UInt64, coldResidentBytes: UInt64)
  {
    control.state.withLock {
      ($0.recycledBackingBytes, $0.recycledResidentBytes, $0.recycledColdResidentBytes)
    }
  }
  public var processorCount: Int { control.cpus }
  public var networkCount: Int { control.networks.count }
  public var aliasDiagnosticEnabled: Bool { control.alias }
  public var refusalCount: Int { control.state.withLock { $0.refusals } }
  /// Releases only the deliberately retained diagnostic alias, on the coordinator.
  public func releaseDiagnosticAlias() throws {
    try control.state.withLock {
      guard control.alias, $0.running, !$0.ended, !$0.stop else { throw NativeFailure.state }
      $0.releaseAlias = true
    }
  }
  public var pluggedBytes: UInt64 { control.state.withLock { $0.plugged } }
  /// One logical device observation; neither number is RSS or physical RAM.
  public var memoryState: (pluggedBytes: UInt64, requestedBytes: UInt64) {
    control.state.withLock { ($0.plugged, $0.requested) }
  }
  /// Coordinator acknowledgement is distinct from the synchronous setter-admission retirement.
  public var memoryControlStatus:
    (generation: UInt64, retired: Bool, quarantined: Bool, backingRetiredBytes: UInt64)
  {
    control.state.withLock {
      (
        $0.memoryGeneration, $0.memoryControlRetired, $0.memoryQuarantineApplied,
        $0.backingRetiredBytes
      )
    }
  }
  /// Cleanup wait, independent of cancellation. A timeout requires outer VM/process retirement.
  public func waitForMemoryControlRetirement(deadline: ContinuousClock.Instant) async throws {
    while true {
      let value = control.state.withLock {
        ($0.memoryControlRetired, $0.memoryQuarantineApplied, $0.ended, $0.error)
      }
      guard value.0 else { throw NativeControlFailure.ownership }
      if value.1 { return }
      if value.2 { throw NativeFailure.stopped(value.3) }
      guard ContinuousClock.now < deadline else { throw NativeControlFailure.quarantineTimedOut }
      await withCheckedContinuation { continuation in
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(5)) {
          continuation.resume()
        }
      }
    }
  }
  /// Changes desired dynamic capacity, not confirmed RAM. Refuses competing or retired authority.
  public func requestMemory(bytes: UInt64) throws {
    try requestMemory(bytes: bytes, owner: nil)
  }
  func claimMemoryControl(minimumResidentBytes: UInt64) throws -> UInt64 {
    try control.state.withLock {
      guard $0.memoryOwner == nil, !$0.memoryControlRetired, $0.memoryGeneration < UInt64.max
      else { throw NativeControlFailure.ownership }
      guard $0.running, !$0.ended, !$0.stop else { throw NativeFailure.state }
      guard $0.plugged == $0.requested else { throw NativeControlFailure.unsettled }
      guard control.geometry.bootBytes + $0.plugged >= minimumResidentBytes else {
        throw NativeControlFailure.belowResidentFloor
      }
      $0.memoryGeneration += 1
      $0.memoryOwner = $0.memoryGeneration
      return $0.memoryGeneration
    }
  }
  func finishMemoryControl(owner: UInt64, reusable: Bool) {
    control.state.withLock {
      precondition($0.memoryOwner == owner, "Only the current governor can release its authority")
      $0.memoryOwner = nil
      if !reusable {
        $0.memoryControlRetired = true
        control.memoryQuarantineRequested.store(true, ordering: .releasing)
      }
    }
  }
  func requestMemory(bytes: UInt64, owner: UInt64?) throws {
    guard bytes <= control.geometry.dynamicBytes, bytes % UInt64(MemoryDevice.block) == 0 else {
      throw NativeFailure.unsupported
    }
    try control.state.withLock {
      guard $0.memoryOwner == owner, !$0.memoryControlRetired else {
        throw NativeControlFailure.ownership
      }
      guard $0.running, !$0.ended, !$0.stop else { throw NativeFailure.state }
      $0.requested = bytes
    }
  }
  public func start() async throws {
    let status = try control.state.withLock { state -> Int32 in
      guard !state.started, !state.stop, !state.ended else { throw NativeFailure.state }
      state.started = true
      // Publication shares the creation lock; a concurrent stop cannot miss the handle.
      let context = Unmanaged.passRetained(control).toOpaque()
      var worker: pthread_t?
      let code = pthread_create(
        &worker, nil,
        { context in
          let owner = Unmanaged<NativeControl>.fromOpaque(context).takeRetainedValue()
          owner.run()
          return nil
        }, context)
      if code == 0 {
        precondition(worker != nil, "Successful pthread_create must return its handle")
        state.worker = UInt(bitPattern: worker!)
      } else {
        Unmanaged<NativeControl>.fromOpaque(context).release()
        state.createFailed = true
        state.ended = true
        state.joinComplete = true
        state.error = "pthread-create \(code)"
      }
      return code
    }
    guard status == 0 else {
      do { try control.resources?.retire() } catch {
        throw NativeFailure.failedStart("pthread-create \(status)", String(describing: error))
      }
      throw NativeFailure.stopped("pthread-create \(status)")
    }
    do {
      let deadline = ContinuousClock.now.advanced(by: .seconds(5))
      while true {
        try Task.checkCancellation()
        let snapshot = control.state.withLock { ($0.running, $0.ended, $0.stop, $0.error) }
        if snapshot.1 { throw NativeFailure.stopped(snapshot.3) }
        if snapshot.2 { throw CancellationError() }
        if snapshot.0 { return }
        guard ContinuousClock.now < deadline else { throw NativeFailure.deadline }
        try await Task.sleep(for: .milliseconds(5))
      }
    } catch {
      let initial = String(describing: error)
      let retirement = await Task { @concurrent in
        do {
          try await self.stop()
          return ""
        } catch { return String(describing: error) }
      }.value
      throw NativeFailure.failedStart(initial, retirement)
    }
  }
  public func stop() async throws {
    let started = control.state.withLock {
      $0.stop = true
      if !$0.started {
        $0.ended = true
        $0.joinComplete = true
      }
      return $0.started
    }
    guard started else {
      try control.resources?.retire()
      return
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !control.state.withLock({ $0.ended }) {
      guard ContinuousClock.now < deadline else { throw NativeFailure.deadline }
      // Cleanup must join even when the caller was cancelled.
      await withCheckedContinuation { continuation in
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(5)) {
          continuation.resume()
        }
      }
    }
    let join = control.state.withLock { state -> UInt? in
      guard !state.joining else { return nil }
      if state.worker == 0 {
        precondition(state.createFailed, "Started worker handle must be published")
        state.joinComplete = true
        return nil
      }
      state.joining = true
      return state.worker
    }
    if let join {
      let status: Int32 = await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
          guard let worker = pthread_t(bitPattern: join) else {
            continuation.resume(returning: EINVAL)
            return
          }
          continuation.resume(returning: pthread_join(worker, nil))
        }
      }
      control.state.withLock {
        $0.joinError = status
        $0.joined = status == 0
        $0.joinComplete = true
      }
    }
    while !control.state.withLock({ $0.joinComplete }) {
      guard ContinuousClock.now < deadline else { throw NativeFailure.deadline }
      await withCheckedContinuation { continuation in
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(5)) {
          continuation.resume()
        }
      }
    }
    guard control.state.withLock({ $0.joinError }) == 0 else { throw NativeFailure.state }
    let error = control.state.withLock { $0.error }
    guard error.isEmpty else { throw NativeFailure.stopped(error) }
  }
  public func dialAgent() async throws -> Vminitd {
    let connection = try await dial(Vminitd.port)
    return try await Vminitd(connection: connection, group: group)
  }
  public func dial(_ port: UInt32) async throws -> FileHandle {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while ContinuousClock.now < deadline {
      let pair = try VsockDevice.pair()
      let token: UInt32
      do {
        token = try control.state.withLock {
          guard $0.running, !$0.stop, !$0.ended, $0.pendingDials.count < 32, $0.commands.count < 64
          else { throw NativeFailure.state }
          let token = $0.nextPort
          $0.nextPort += 1
          $0.pendingDials.insert(token)
          $0.commands.append(.open(port, pair.0, token))
          return token
        }
      } catch {
        _ = Darwin.close(pair.0)
        _ = Darwin.close(pair.1)
        throw error
      }
      do {
        let attempt = min(deadline, ContinuousClock.now.advanced(by: .seconds(1)))
        while ContinuousClock.now < attempt {
          try Task.checkCancellation()
          if let connected = control.state.withLock({ $0.connected[token] }) {
            if connected {
              control.state.withLock {
                $0.pendingDials.remove(token)
                $0.connected.removeValue(forKey: token)
              }
              return FileHandle(fileDescriptor: pair.1, closeOnDealloc: false)
            }
            break
          }
          if control.state.withLock({ $0.ended }) { throw NativeFailure.state }
          try await Task.sleep(for: .milliseconds(5))
        }
      } catch {
        control.state.withLock {
          $0.pendingDials.remove(token)
          $0.connected.removeValue(forKey: token)
          if !$0.ended { $0.commands.append(.cancel(token)) }
        }
        _ = Darwin.close(pair.1)
        throw error
      }
      control.state.withLock {
        $0.pendingDials.remove(token)
        $0.connected.removeValue(forKey: token)
        if !$0.ended { $0.commands.append(.cancel(token)) }
      }
      _ = Darwin.close(pair.1)
      try await Task.sleep(for: .milliseconds(25))
    }
    throw NativeFailure.deadline
  }
  public func listen(_ port: UInt32) throws -> VsockListener {
    let listener = VsockListener(port: port) { [control] port in
      _ = control.state.withLock { $0.listeners.removeValue(forKey: port) }
    }
    try control.state.withLock {
      guard $0.running, !$0.ended, !$0.stop, $0.listeners[port] == nil,
        $0.listeners.count < 32
      else { throw NativeFailure.state }
      $0.listeners[port] = listener
    }
    return listener
  }
}
