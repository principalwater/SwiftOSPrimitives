import Containerization
import ContainerizationOCI
import CryptoKit
import Darwin
import Foundation
import Synchronization

/// Owns one trusted, confined monitor for one native guest boot. This does not admit workloads.
/// Callers must join their governor before shutdown and retain this owner through native VM stop.
public final class NativeMemoryService: Sendable {
  public enum Phase: String, Sendable {
    case idle, starting, live, stopping, stopped, failed, retired
  }
  public struct Snapshot: Sendable {
    public let phase: Phase
    public let stage: String
    public let pid: Int32?
    public let waited: Bool
    public let deleted: Bool
    public let rootUnmounted: Bool
    public let pendingOperations: Int
    public let memoryBytes: UInt64?
    public let diagnostics: String
    public let primaryError: String
    public let cleanupErrors: [String]
  }
  private struct State {
    var phase = Phase.idle
    var stage = "artifact-pinned"
    var program: Int32
    var listeners: [VsockListener] = []
    var handles: [FileHandle] = []
    var wire: MemorySocketWire?
    var session: NativeMemorySession?
    var startup: Task<Void, Never>?
    var shutdown: Task<Void, Never>?
    var startupDone = false
    var shutdownDone = false
    var signal: AsyncStream<Result<Void, any Error>>.Continuation?
    var pid: Int32?
    var waited = false
    var deleted = false
    var rootUnmounted = false
    var memoryBytes: UInt64?
    var primaryError = ""
    var cleanupErrors: [String] = []
  }
  private let state: Mutex<State>
  private let vm: NativeVirtualMachine
  private let agent: Vminitd
  private let digest: String
  private let id = "native-memory-" + UUID().uuidString.lowercased()
  private var root: String { "/run/" + id }

  /// Borrows a read-only, regular executable descriptor; pins an independent duplicate.
  /// The digest must originate in the caller's authenticated artifact manifest, not guest input.
  public init(
    vm: NativeVirtualMachine, agent: Vminitd, programDescriptor: Int32, sha256: String
  ) throws {
    guard sha256.utf8.count == 64,
      sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw NativeControlFailure.arguments }
    let descriptor = fcntl(programDescriptor, F_DUPFD_CLOEXEC, 3)
    guard descriptor >= 0 else { throw MemorySocketFailure.system("program-duplicate", errno) }
    do { _ = try Self.programInfo(descriptor) } catch {
      if Darwin.close(descriptor) != 0 {
        throw MemorySocketFailure.initialization(
          String(describing: error), [.system("program-close", errno)])
      }
      throw error
    }
    self.vm = vm
    self.agent = agent
    digest = sha256
    state = Mutex(State(program: descriptor))
  }

  deinit { abort() }

  public var snapshot: Snapshot {
    state.withLock {
      Snapshot(
        phase: $0.phase, stage: $0.stage, pid: $0.pid, waited: $0.waited, deleted: $0.deleted,
        rootUnmounted: $0.rootUnmounted,
        pendingOperations: ($0.startup != nil && !$0.startupDone ? 1 : 0)
          + ($0.shutdown != nil && !$0.shutdownDone ? 1 : 0),
        memoryBytes: $0.memoryBytes, diagnostics: $0.wire?.diagnosticText ?? "",
        primaryError: $0.primaryError,
        cleanupErrors: $0.cleanupErrors + ($0.wire?.cleanupErrors.map(Self.describe) ?? []))
    }
  }

  /// No session escapes before the bounded bootstrap and actual resource checks succeed.
  public var session: NativeMemorySession {
    get throws {
      try state.withLock {
        guard $0.phase == .live, let session = $0.session else {
          throw NativeControlFailure.ownership
        }
        return session
      }
    }
  }

  /// Consumes this boot's monitor lease once; timeout never detaches the actual bootstrap task.
  public func start(until deadline: ContinuousClock.Instant) async throws {
    try Task.checkCancellation()
    guard ContinuousClock.now < deadline else { throw NativeControlFailure.lifetimeExpired }
    let (events, signal) = AsyncStream<Result<Void, any Error>>.makeStream(
      bufferingPolicy: .bufferingOldest(1))
    try state.withLock {
      guard $0.phase == .idle else { throw NativeControlFailure.ownership }
      try vm.claimMemoryService()
      $0.phase = .starting
      $0.signal = signal
      $0.startup = Task { await self.performStartup(until: deadline, signal: signal) }
    }
    do {
      try await wait(events, signal: signal, until: deadline, timeout: .lifetimeExpired)
      let task = try state.withLock { value -> Task<Void, Never>? in
        guard value.phase == .starting, ContinuousClock.now < deadline else {
          throw NativeControlFailure.ownership
        }
        return value.startup
      }
      await task?.value
      try Task.checkCancellation()
      try state.withLock {
        guard $0.phase == .starting, ContinuousClock.now < deadline else {
          throw NativeControlFailure.lifetimeExpired
        }
        $0.phase = .live
        $0.signal = nil
      }
    } catch {
      abort(cause: error)
      throw error
    }
  }

  /// Requires the governor's actual join first. Uses only the caller's remaining drain budget.
  public func shutdown(until deadline: ContinuousClock.Instant) async throws {
    try Task.checkCancellation()
    let (events, signal) = AsyncStream<Result<Void, any Error>>.makeStream(
      bufferingPolicy: .bufferingOldest(1))
    let admitted = try state.withLock { value -> Bool in
      if value.phase == .stopped { return false }
      guard value.phase == .live else { throw NativeControlFailure.ownership }
      value.phase = .stopping
      value.signal = signal
      value.shutdown = Task { await self.performShutdown(until: deadline, signal: signal) }
      return true
    }
    guard admitted else { return }
    do {
      try await wait(events, signal: signal, until: deadline, timeout: .drainTimedOut)
      let task = state.withLock { $0.shutdown }
      await task?.value
      try Task.checkCancellation()
      try state.withLock {
        guard $0.phase == .stopping, ContinuousClock.now < deadline else {
          throw NativeControlFailure.drainTimedOut
        }
        $0.phase = .stopped
        $0.signal = nil
      }
    } catch {
      abort(cause: error)
      throw error
    }
  }

  /// Revokes admission and closes known IO. Does not claim that RPCs or the guest were reaped.
  /// Never cancels the bootstrap: it must consume and explicitly close late accepted handles.
  public func abort() { abort(cause: NativeControlFailure.disconnected) }

  private func abort(cause: any Error) {
    let owned = state.withLock { value in
      if value.phase != .stopped && value.phase != .retired {
        value.phase = .failed
        if value.primaryError.isEmpty { value.primaryError = Self.describe(cause) }
      }
      let owned = (value.program, value.handles, value.listeners, value.wire, value.signal)
      value.program = -1
      value.handles = []
      value.signal = nil
      return owned
    }
    owned.4?.yield(.failure(cause))
    owned.4?.finish()
    for listener in owned.2 { finish(listener) }
    for handle in owned.1 { close(handle) }
    if owned.0 >= 0, Darwin.close(owned.0) != 0 { cleanup("program-close \(errno)") }
    owned.3?.close()
  }

  /// Called only after native stop joined every vCPU. Retains hung operations on failure.
  /// Whole-VM retirement is distinct from a successful guest wait/delete/unmount sequence.
  public func joinAfterNativeStop(until deadline: ContinuousClock.Instant) async throws {
    guard vm.memoryServiceCanRetire else { throw NativeControlFailure.unsettled }
    abort()
    while true {
      let tasks = state.withLock { value -> (Task<Void, Never>?, Task<Void, Never>?)? in
        guard value.startup == nil || value.startupDone,
          value.shutdown == nil || value.shutdownDone
        else { return nil }
        return (value.startup, value.shutdown)
      }
      if let tasks {
        await tasks.0?.value
        await tasks.1?.value
        guard ContinuousClock.now < deadline else { throw NativeControlFailure.drainTimedOut }
        state.withLock {
          $0.startup = nil
          $0.shutdown = nil
          $0.session = nil
          $0.phase = .retired
        }
        return
      }
      guard ContinuousClock.now < deadline else { throw NativeControlFailure.drainTimedOut }
      try await Task.sleep(
        until: min(deadline, .now.advanced(by: .milliseconds(5))), clock: .continuous)
    }
  }

  private func wait(
    _ events: AsyncStream<Result<Void, any Error>>,
    signal: AsyncStream<Result<Void, any Error>>.Continuation,
    until deadline: ContinuousClock.Instant, timeout: NativeControlFailure
  ) async throws {
    let timer = Task {
      do {
        try await Task.sleep(until: deadline, clock: .continuous)
        signal.yield(.failure(timeout))
        signal.finish()
      } catch {}
    }
    let result = await withTaskCancellationHandler {
      await events.first(where: { _ in true })
    } onCancel: {
      self.abort(cause: CancellationError())
    }
    timer.cancel()
    await timer.value
    try Task.checkCancellation()
    guard ContinuousClock.now < deadline else { throw timeout }
    guard let result else { throw NativeControlFailure.disconnected }
    try result.get()
  }

  private func check(_ phase: Phase, _ stage: String, _ deadline: ContinuousClock.Instant) throws {
    try state.withLock {
      guard $0.phase == phase else { throw NativeControlFailure.ownership }
      guard ContinuousClock.now < deadline else {
        throw phase == .stopping
          ? NativeControlFailure.drainTimedOut : NativeControlFailure.lifetimeExpired
      }
      $0.stage = stage
    }
  }
  private func cleanup(_ text: String) {
    state.withLock {
      if $0.cleanupErrors.count < 8 { $0.cleanupErrors.append(Self.describe(text)) }
    }
  }
  private static func describe(_ value: Any) -> String {
    String(String(describing: value).prefix(512))
  }
  private func finish(_ listener: VsockListener) {
    do { try listener.finish() } catch { cleanup("listener: \(error)") }
  }
  private func close(_ handle: FileHandle) {
    do { try handle.close() } catch { cleanup("stdio: \(error)") }
  }

  @concurrent private func performStartup(
    until deadline: ContinuousClock.Instant,
    signal: AsyncStream<Result<Void, any Error>>.Continuation
  ) async {
    let result: Result<Void, any Error>
    do {
      try await bootstrap(until: deadline)
      result = .success(())
    } catch {
      abort(cause: error)
      result = .failure(error)
    }
    // finish() leaves buffered handles in the AsyncStream; consume them even after failed admission.
    let listeners = state.withLock { $0.listeners }
    for listener in listeners {
      finish(listener)
      for await handle in listener { close(handle) }
    }
    state.withLock { $0.startupDone = true }
    signal.yield(result)
    signal.finish()
  }

  private func bootstrap(until deadline: ContinuousClock.Instant) async throws {
    let bytes = try program(until: deadline)
    try check(.starting, "mkdir-requested", deadline)
    try await agent.mkdir(path: root, all: false, perms: 0o700)
    try check(.starting, "mount-requested", deadline)
    try await agent.mount(
      .init(
        type: "tmpfs", source: "tmpfs", destination: root,
        options: ["nosuid", "nodev", "size=16777216", "mode=700"]))
    for name in ["proc", "dev", "etc"] {
      try check(.starting, "directory-" + name, deadline)
      try await agent.mkdir(path: root + "/" + name, all: false, perms: 0o755)
    }
    for name in ["null", "ptmx"] {
      try check(.starting, "device-" + name, deadline)
      try await agent.writeFile(
        path: root + "/dev/" + name, data: Data(), flags: .init(create: true), mode: 0o600)
    }
    for (name, text) in [("passwd", "root:x:0:0:root:/:/monitor\n"), ("group", "root:x:0:\n")] {
      try check(.starting, "identity-" + name, deadline)
      try await agent.writeFile(
        path: root + "/etc/" + name, data: Data(text.utf8), flags: .init(create: true), mode: 0o400)
    }
    var offset = 0
    while offset < bytes.count {
      try check(.starting, "upload", deadline)
      let end = min(offset + 65536, bytes.count)
      try await agent.writeFile(
        path: root + "/monitor", data: bytes.subdata(in: offset..<end),
        flags: .init(create: offset == 0, append: offset != 0), mode: 0o500)
      offset = end
    }
    let ports: [UInt32] = [0x0700_0001, 0x0700_0002, 0x0700_0003]
    let listeners = try state.withLock { value -> [VsockListener] in
      guard value.phase == .starting, ContinuousClock.now < deadline else {
        throw NativeControlFailure.ownership
      }
      for port in ports { value.listeners.append(try vm.listen(port)) }
      return value.listeners
    }
    let spec = Spec(
      version: "1.2.0",
      process: .init(
        args: ["/monitor"], noNewPrivileges: true,
        capabilities: .init(
          bounding: [], effective: [], inheritable: [], permitted: [], ambient: []),
        user: .init(uid: 0, gid: 0),
        rlimits: [
          .init(type: "RLIMIT_NOFILE", hard: 64, soft: 64),
          .init(type: "RLIMIT_CORE", hard: 0, soft: 0),
        ]),
      mounts: [
        .init(
          type: "proc", source: "proc", destination: "/proc",
          options: ["nosuid", "nodev", "noexec"]),
        .init(type: "bind", source: "/dev/null", destination: "/dev/null", options: ["bind"]),
      ], root: .init(path: root, readonly: true),
      linux: .init(
        resources: .init(memory: .init(limit: 64 << 20), pids: .init(limit: 8)),
        cgroupsPath: "/container/" + id,
        namespaces: [.init(type: .pid), .init(type: .mount), .init(type: .uts), .init(type: .ipc)],
        readonlyPaths: ["/proc/sys", "/proc/sysrq-trigger", "/proc/irq", "/proc/bus", "/proc/fs"]))
    try check(.starting, "create-requested", deadline)
    try await agent.createProcess(
      id: id, containerID: id, stdinPort: ports[0], stdoutPort: ports[1], stderrPort: ports[2],
      ociRuntimePath: nil, configuration: spec, options: nil)
    for listener in listeners {
      try check(.starting, "stdio-accept", deadline)
      guard let handle = await listener.first(where: { _ in true }) else {
        throw NativeControlFailure.disconnected
      }
      let accepted = state.withLock { value in
        guard value.phase == .starting else { return false }
        value.handles.append(handle)
        return true
      }
      if !accepted {
        close(handle)
        throw NativeControlFailure.ownership
      }
      finish(listener)
    }
    let pair = try state.withLock { value -> (NativeMemorySession, [FileHandle]) in
      guard value.phase == .starting, value.handles.count == 3 else {
        throw NativeControlFailure.ownership
      }
      let wire = try MemorySocketWire(
        input: value.handles[0], output: value.handles[1], error: value.handles[2])
      let session = try NativeMemorySession(
        wire: wire, maximumGuestBytes: vm.memoryGeometry.maximumBytes)
      value.wire = wire
      value.session = session
      let handles = value.handles
      value.handles = []
      return (session, handles)
    }
    for handle in pair.1 { close(handle) }
    try check(.starting, "start-requested", deadline)
    let pid = try await agent.startProcess(id: id, containerID: id)
    state.withLock { $0.pid = pid }
    guard pid > 1 else { throw NativeControlFailure.ownership }
    try check(.starting, "handshake", deadline)
    try await pair.0.start(until: min(deadline, .now.advanced(by: .seconds(5))))
    try check(.starting, "resource-verification", deadline)
    let statistics = try await agent.containerStatistics(
      containerIDs: [id], categories: [.memory, .process, .memoryEvents])
    guard statistics.count == 1, let stats = statistics.first, stats.id == id,
      let memory = stats.memory, memory.limitBytes == 64 << 20, memory.usageBytes > 0,
      memory.usageBytes <= memory.limitBytes,
      let process = stats.process, process.limit == 8, process.current == 1,
      let events = stats.memoryEvents, events.oom == 0, events.oomKill == 0
    else { throw NativeControlFailure.invariant }
    try check(.starting, "ready", deadline)
    state.withLock { $0.memoryBytes = memory.usageBytes }
    guard state.withLock({ $0.cleanupErrors.isEmpty }) else { throw NativeControlFailure.unsettled }
  }

  @concurrent private func performShutdown(
    until deadline: ContinuousClock.Instant,
    signal: AsyncStream<Result<Void, any Error>>.Continuation
  ) async {
    let result: Result<Void, any Error>
    do {
      try check(.stopping, "quit-requested", deadline)
      guard let session = state.withLock({ $0.session }) else {
        throw NativeControlFailure.ownership
      }
      try await session.quit(until: min(deadline, .now.advanced(by: .seconds(5))))
      try check(.stopping, "wait-requested", deadline)
      let seconds = max(1, ContinuousClock.now.duration(to: deadline).components.seconds)
      let status = try await agent.waitProcess(id: id, containerID: id, timeoutInSeconds: seconds)
      state.withLock { $0.waited = true }
      guard status.exitCode == 0 else { throw NativeControlFailure.invariant }
      try check(.stopping, "delete-requested", deadline)
      try await agent.deleteProcess(id: id, containerID: id)
      state.withLock { $0.deleted = true }
      try check(.stopping, "unmount-requested", deadline)
      try await agent.umount(path: root, flags: 0)
      state.withLock { $0.rootUnmounted = true }
      try check(.stopping, "stopped", deadline)
      result = .success(())
    } catch {
      abort(cause: error)
      result = .failure(error)
    }
    state.withLock { $0.shutdownDone = true }
    signal.yield(result)
    signal.finish()
  }

  private static func programInfo(_ descriptor: Int32) throws -> stat {
    var info = stat()
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, flags & O_ACCMODE == O_RDONLY,
      fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o022 == 0,
      info.st_size >= 64, info.st_size <= 16 << 20
    else { throw NativeControlFailure.ownership }
    return info
  }

  private func program(until deadline: ContinuousClock.Instant) throws -> Data {
    let descriptor = try state.withLock { value -> Int32 in
      guard value.phase == .starting, value.program >= 0 else {
        throw NativeControlFailure.ownership
      }
      let result = value.program
      value.program = -1
      return result
    }
    var closed = false
    defer {
      if !closed, Darwin.close(descriptor) != 0 { cleanup("program-close \(errno)") }
    }
    let before = try Self.programInfo(descriptor)
    var data = Data(count: Int(before.st_size))
    try data.withUnsafeMutableBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        try check(.starting, "artifact-read", deadline)
        let count = pread(
          descriptor, bytes.baseAddress! + offset, min(65536, bytes.count - offset), off_t(offset))
        if count < 0, errno == EINTR { continue }
        guard count > 0 else {
          throw MemorySocketFailure.system("program-read", count < 0 ? errno : EIO)
        }
        offset += count
      }
    }
    let after = try Self.programInfo(descriptor)
    guard before.st_dev == after.st_dev, before.st_ino == after.st_ino,
      before.st_size == after.st_size, before.st_mode == after.st_mode,
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
      data.starts(with: [0x7f, 0x45, 0x4c, 0x46, 2, 1, 1]),
      data[16] == 2, data[17] == 0, data[18] == 183, data[19] == 0,
      SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest
    else { throw NativeControlFailure.ownership }
    closed = true
    guard Darwin.close(descriptor) == 0 else {
      throw MemorySocketFailure.system("program-close", errno)
    }
    try check(.starting, "artifact-verified", deadline)
    return data
  }
}
