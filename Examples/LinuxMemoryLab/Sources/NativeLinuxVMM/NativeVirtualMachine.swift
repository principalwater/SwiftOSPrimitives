import Containerization
import Darwin
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
    var requested = UInt64(MemoryDevice.capacity)
    var plugged: UInt64 = 0
    var error = ""
    var result = Data()
    var commands: [Command] = []
    var listeners: [UInt32: VsockListener] = [:]
    var connected: [UInt32: Bool] = [:]
    var nextPort: UInt32 = 0x2000_0000
  }
  let state = Mutex(State())
  let kernel: URL
  let initfs: URL
  let rootfs: URL
  let console: URL
  let held: Bool
  let alias: Bool
  let cpus: Int
  let networks: [IsolatedNetwork]

  init(
    kernel: URL, initfs: URL, rootfs: URL, console: URL, held: Bool, alias: Bool, cpus: Int = 1,
    networks: [IsolatedNetwork] = []
  ) {
    self.kernel = kernel
    self.initfs = initfs
    self.rootfs = rootfs
    self.console = console
    self.held = held
    self.alias = alias
    self.cpus = cpus
    self.networks = networks
  }
  func run() {
    let machine = LinuxMachine()
    machine.control = self
    machine.capacity = 1024 << 20
    machine.cpuCount = cpus
    machine.dynamicMemory = MemoryDevice(held: held, aliasControl: alias)
    let lease = NativeProcessLease.claimed.withLock { claimed -> Bool in
      guard !claimed else { return false }
      claimed = true
      return true
    }
    var primary = ""
    do {
      guard lease else { throw NativeFailure.processBusy }
      machine.disk = try BlockDevice(path: initfs.path, readOnly: true)
      machine.rootDisk = try BlockDevice(path: rootfs.path, interrupt: 37)
      machine.vsock = VsockDevice(control: self)
      for network in networks { machine.networks.append(try NetworkDevice(network: network)) }
      let consoleDescriptor = open(
        console.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
      guard consoleDescriptor >= 0 else {
        throw NativeFailure.stopped("console-open \(errno)")
      }
      machine.consoleSink = FileHandle(fileDescriptor: consoleDescriptor, closeOnDealloc: true)
      try machine.boot(kernel: Data(contentsOf: kernel, options: .mappedIfSafe), initrd: Data())
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
    if lease, !machine.created, cleanup.isEmpty {
      NativeProcessLease.claimed.withLock { $0 = false }
    }
    let result: [String: Any] = [
      "primaryError": primary, "cleanupErrors": cleanup,
      "vmCreated": machine.wasCreated, "vmDestroyed": machine.wasCreated && !machine.created,
      "memoryObservations": machine.dynamicMemory?.observations ?? [],
      "memoryRefusals": machine.dynamicMemory?.refusals ?? [],
      "networks": machine.networks.map {
        ["index": $0.index, "txPackets": $0.txPackets, "rxPackets": $0.rxPackets]
      },
      "cpus": machine.cpus?.statistics ?? [],
      "quiescentEpochs": machine.cpus?.epoch ?? 0,
      "maximumScheduledVCPUs": machine.cpus?.maximumScheduled ?? 0,
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

/// Finite, private-NIC research backend for the current Apple Containerization API.
public final class NativeVirtualMachineManager: VirtualMachineManager {
  public let kernel: URL
  public let initfs: URL
  public let console: URL
  public let held: Bool
  public let aliasControl: Bool
  public let group: MultiThreadedEventLoopGroup
  private let owner = Mutex<NativeVirtualMachine?>(nil)

  public init(
    kernel: URL, initfs: URL, console: URL, held: Bool = false,
    aliasControl: Bool = false, group: MultiThreadedEventLoopGroup
  ) {
    self.kernel = kernel
    self.initfs = initfs
    self.console = console
    self.held = held
    self.aliasControl = aliasControl
    self.group = group
  }
  public var instance: NativeVirtualMachine? { owner.withLock { $0 } }
  public func create(config: some VMCreationConfig) async throws -> any VirtualMachineInstance {
    let config = config.configuration
    guard (1...4).contains(config.cpus), config.memoryInBytes == 1152 << 20,
      config.interfaces.count <= 2, !config.nestedVirtualization, config.extensions.isEmpty,
      config.mountsByID.count == 1, let entry = config.mountsByID.first,
      let mount = entry.value.first, mount.type == "ext4", mount.destination == "/",
      case .virtioblk(let blockOptions) = mount.runtimeOptions, blockOptions.isEmpty
    else { throw NativeFailure.unsupported }
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
      console: console, held: held, alias: aliasControl, cpus: config.cpus, networks: networks)
    let machine = NativeVirtualMachine(
      control: control, group: group, id: entry.key,
      attachments: attachments)
    try owner.withLock {
      guard $0 == nil else { throw NativeFailure.state }
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
  public func requestMemory(bytes: UInt64) throws {
    guard bytes <= MemoryDevice.capacity, bytes % UInt64(MemoryDevice.block) == 0 else {
      throw NativeFailure.unsupported
    }
    try control.state.withLock {
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
    guard status == 0 else { throw NativeFailure.stopped("pthread-create \(status)") }
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
    guard started else { return }
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
