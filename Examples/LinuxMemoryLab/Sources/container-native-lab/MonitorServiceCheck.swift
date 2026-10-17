import Containerization
import ContainerizationOCI
import CryptoKit
import Darwin
import Foundation
import NIOPosix
import NativeLinuxVMM

/// Finite G0 integration consumer, not a product process owner or a guest-root execution API.
/// RPC hangs still rely on the unchanged native 120 s qualification fence and outer process
/// retirement. Product admission stays closed until its independent RPC/stdio owners qualify.
enum MonitorServiceCheck {
  enum Failure: Error { case check(String) }
  enum Scenario: String {
    case normal, badSequence, stdinEOF, partialEOF, nonroot, killed, oversized, controlByte
    var expectedExit: Int32 {
      switch self {
      case .normal, .stdinEOF: 0
      case .badSequence, .partialEOF, .nonroot, .oversized, .controlByte: 1
      case .killed: 128 + SIGKILL
      }
    }
  }

  private final class Wire {
    let handle: FileHandle
    private var closed = false
    init(_ handle: FileHandle) throws {
      self.handle = handle
      var admitted = false
      defer { if !admitted { try? handle.close() } }
      let fd = handle.fileDescriptor
      let flags = fcntl(fd, F_GETFL)
      guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
        fcntl(fd, F_SETFD, FD_CLOEXEC) == 0
      else { throw Failure.check("wire flags \(errno)") }
      var one: Int32 = 1
      guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, 4) == 0 else {
        throw Failure.check("wire sigpipe \(errno)")
      }
      admitted = true
    }
    deinit { try? handle.close() }

    func send(_ text: String) throws {
      guard !closed else { throw Failure.check("closed input") }
      let bytes = Array(text.utf8)
      guard !bytes.isEmpty, bytes.count <= 64 else { throw Failure.check("command size") }
      var count: Int
      repeat { count = Darwin.write(handle.fileDescriptor, bytes, bytes.count) }
      while count < 0 && errno == EINTR
      guard count == bytes.count else { throw Failure.check("wire write \(count)/\(errno)") }
    }

    func line(until deadline: ContinuousClock.Instant) async throws -> String {
      var bytes: [UInt8] = []
      bytes.reserveCapacity(73)
      while ContinuousClock.now < deadline {
        try Task.checkCancellation()
        var byte: UInt8 = 0
        let count = Darwin.read(handle.fileDescriptor, &byte, 1)
        if count < 0, errno == EINTR { continue }
        if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
          try await Task.sleep(until: min(.now.advanced(by: .milliseconds(5)), deadline))
          continue
        }
        guard count == 1 else { throw Failure.check("wire read \(count)/\(errno)") }
        if byte == 10 { return String(decoding: bytes, as: UTF8.self) }
        guard (32...126).contains(byte), bytes.count < 72 else {
          throw Failure.check("wire framing")
        }
        bytes.append(byte)
      }
      throw Failure.check("wire deadline")
    }

    func contentsUntilEOF(until deadline: ContinuousClock.Instant, limit: Int) async throws
      -> String
    {
      var bytes: [UInt8] = []
      while ContinuousClock.now < deadline {
        try Task.checkCancellation()
        var byte: UInt8 = 0
        let count = Darwin.read(handle.fileDescriptor, &byte, 1)
        if count == 0 { return String(decoding: bytes, as: UTF8.self) }
        if count < 0, errno == EINTR { continue }
        if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
          try await Task.sleep(until: min(.now.advanced(by: .milliseconds(5)), deadline))
          continue
        }
        guard count == 1, bytes.count < limit else { throw Failure.check("bounded EOF read") }
        bytes.append(byte)
      }
      throw Failure.check("EOF deadline")
    }

    func close() throws {
      guard !closed else { return }
      closed = true
      try handle.close()
    }
  }

  private static func artifact(_ source: URL) throws -> Data {
    let fd = open(source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { throw Failure.check("artifact open \(errno)") }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? file.close() }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == getuid(), info.st_nlink == 1, info.st_size > 0,
      info.st_size <= 16 << 20,
      let bytes = try file.read(upToCount: (16 << 20) + 1), bytes.count == info.st_size,
      bytes.starts(with: [0x7f, 0x45, 0x4c, 0x46])
    else { throw Failure.check("artifact geometry") }
    guard let expected = ProcessInfo.processInfo.environment["SWIFTOS_MONITOR_SHA256"],
      expected.count == 64,
      SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == expected
    else { throw Failure.check("artifact digest") }
    return bytes
  }

  private static func upload(_ bytes: Data, path: String, mode: UInt32, agent: Vminitd)
    async throws
  {
    var offset = 0
    while offset < bytes.count {
      let end = min(offset + 65536, bytes.count)
      try await agent.writeFile(
        path: path, data: bytes.subdata(in: offset..<end),
        flags: .init(create: offset == 0, append: offset != 0), mode: mode)
      offset = end
    }
  }

  static func run(args: [String]) async throws {
    guard let scenario = Scenario(
      rawValue: ProcessInfo.processInfo.environment["SWIFTOS_LAB_MONITOR_SCENARIO"] ?? "normal")
    else { throw Failure.check("scenario") }
    let output = URL(filePath: args[3])
    try FileManager.default.createDirectory(
      at: output, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let fd = open(args[7], O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw Failure.check("boot open \(errno)") }
    defer { Darwin.close(fd) }
    let resources = try NativeBootResources(directoryDescriptor: fd)
    let geometry = try NativeMemoryGeometry(bootBytes: 512 << 20, dynamicBytes: 2560 << 20)
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    let manager = NativeVirtualMachineManager(
      resources: resources, group: group, memoryGeometry: geometry, executionPolicy: .qualification,
      classicBallooning: true)
    var agent: Vminitd?
    var primary = ""
    var cleanup: [String] = []
    var transcript: [String] = []
    var rootRefusal = ""
    var pid: Int32 = -1
    var exitCode: Int32 = -1
    var deleted = false
    var diagnostics = ""
    var listeners: [VsockListener] = []
    var wires: [Wire] = []
    let id = "memory-monitor-" + UUID().uuidString.lowercased()
    let root = "/run/" + id
    do {
      let instance = try await manager.create(
        config: StandardVMConfig(configuration: .init(
          cpus: 2, memoryInBytes: geometry.maximumBytes, interfaces: [],
          mountsByID: [
            id: [.block(format: "ext4", source: resources.mountSource, destination: "/")]
          ])))
      try await instance.start()
      guard let vm = manager.instance else { throw Failure.check("native instance") }
      let client = try await vm.dialAgent()
      agent = client
      try await client.standardSetup()
      do {
        try await client.createProcess(
          id: id, containerID: nil, stdinPort: nil, stdoutPort: nil, stderrPort: nil,
          ociRuntimePath: nil, configuration: .init(process: .init(args: ["/unused"])),
          options: nil)
        throw Failure.check("unexpected guest-root process support")
      } catch {
        rootRefusal = String(describing: error)
        guard rootRefusal.contains("processes in the root of the vm not implemented") else {
          throw error
        }
      }
      try await client.mkdir(path: root, all: false, perms: 0o700)
      try await client.mount(.init(
        type: "tmpfs", source: "tmpfs", destination: root,
        options: ["nosuid", "nodev", "size=16777216",
          scenario == .nonroot ? "mode=755" : "mode=700"]))
      for directory in ["proc", "dev", "etc"] {
        try await client.mkdir(path: root + "/" + directory, all: false, perms: 0o755)
      }
      for name in ["null", "ptmx"] {
        try await client.writeFile(
          path: root + "/dev/" + name, data: Data(), flags: .init(create: true), mode: 0o600)
      }
      try await client.writeFile(
        path: root + "/etc/passwd",
        data: Data("root:x:0:0:root:/:/monitor\nnobody:x:65534:65534::/:/monitor\n".utf8),
        flags: .init(create: true), mode: 0o400)
      try await client.writeFile(
        path: root + "/etc/group", data: Data("root:x:0:\nnogroup:x:65534:\n".utf8),
        flags: .init(create: true), mode: 0o400)
      try await upload(
        artifact(URL(filePath: args[5])), path: root + "/monitor",
        mode: scenario == .nonroot ? 0o555 : 0o500, agent: client)
      // A dedicated block below LinuxContainer's allocator; never reused during this VM boot.
      let ports: [UInt32] = [0x0700_0001, 0x0700_0002, 0x0700_0003]
      for port in ports { listeners.append(try vm.listen(port)) }
      let spec = Spec(
        version: "1.2.0",
        process: .init(
          args: ["/monitor"], noNewPrivileges: true, capabilities: .init(),
          user: .init(uid: scenario == .nonroot ? 65534 : 0, gid: scenario == .nonroot ? 65534 : 0),
          rlimits: [.init(type: "RLIMIT_NOFILE", hard: 64, soft: 64),
            .init(type: "RLIMIT_CORE", hard: 0, soft: 0)]),
        mounts: [
          .init(type: "proc", source: "proc", destination: "/proc",
            options: ["nosuid", "nodev", "noexec"]),
          .init(type: "bind", source: "/dev/null", destination: "/dev/null", options: ["bind"]),
        ],
        root: .init(path: root, readonly: true),
        linux: .init(
          resources: .init(memory: .init(limit: 64 << 20), pids: .init(limit: 8)),
          cgroupsPath: "/container/" + id,
          namespaces: [
            .init(type: .pid), .init(type: .mount), .init(type: .uts), .init(type: .ipc),
          ],
          readonlyPaths: ["/proc/sys"]))
      try await client.createProcess(
        id: id, containerID: id, stdinPort: ports[0], stdoutPort: ports[1], stderrPort: ports[2],
        ociRuntimePath: nil, configuration: spec, options: nil)
      for listener in listeners {
        guard let handle = await listener.first(where: { _ in true }) else {
          throw Failure.check("missing stdio")
        }
        wires.append(try Wire(handle))
        try listener.finish()
      }
      pid = try await client.startProcess(id: id, containerID: id)
      guard pid > 1 else { throw Failure.check("invalid monitor pid") }
      if scenario != .nonroot {
        let ready = try await wires[1].line(until: .now.advanced(by: .seconds(5)))
        transcript.append(ready)
        try validate(ready, sequence: nil, maximum: geometry.maximumBytes)
      }
      switch scenario {
      case .normal:
        for (offset, command) in ["OBS", "OBS_REFRESH", "QUIT"].enumerated() {
          let sequence = offset + 1
          try wires[0].send("\(command) \(sequence)\n")
          let line = try await wires[1].line(until: .now.advanced(by: .seconds(5)))
          transcript.append(line)
          try validate(line, sequence: sequence, maximum: geometry.maximumBytes)
        }
      case .badSequence: try wires[0].send("OBS 2\n")
      case .oversized: try wires[0].send(String(repeating: "X", count: 64))
      case .controlByte: try wires[0].send("OBS 1\r\n")
      case .stdinEOF: try wires[0].close()
      case .partialEOF:
        try wires[0].send("OBS ")
        try wires[0].close()
      case .nonroot: break
      case .killed: try await client.signalProcess(id: id, containerID: id, signal: SIGKILL)
      }
      let status = try await client.waitProcess(id: id, containerID: id, timeoutInSeconds: 5)
      exitCode = Int32(status.exitCode)
      guard exitCode == scenario.expectedExit else {
        throw Failure.check("monitor exit \(exitCode)")
      }
      let trailing = try await wires[1].contentsUntilEOF(
        until: .now.advanced(by: .seconds(5)), limit: 73)
      guard trailing.isEmpty else { throw Failure.check("unexpected output after exit") }
      diagnostics = try await wires[2].contentsUntilEOF(
        until: .now.advanced(by: .seconds(5)), limit: 2048)
      switch scenario {
      case .badSequence, .partialEOF, .oversized, .controlByte:
        guard diagnostics.contains("framing") else {
          throw Failure.check("missing framing failure")
        }
      case .nonroot:
        // World-searchable root and executable deliberately exclude an exec permission denial.
        guard diagnostics.contains("system(13)") else {
          throw Failure.check("missing stat_refresh permission refusal: " + diagnostics)
        }
      case .normal, .stdinEOF, .killed:
        guard diagnostics.isEmpty else { throw Failure.check("unexpected stderr: " + diagnostics) }
      }
      try await client.deleteProcess(id: id, containerID: id)
      deleted = true
      for wire in wires { try wire.close() }
      wires = []
      try await client.umount(path: root, flags: 2)
    } catch { primary = String(describing: error) }
    for listener in listeners {
      do { try listener.finish() } catch { cleanup.append("listener \(error)") }
    }
    for wire in wires {
      do { try wire.close() } catch { cleanup.append("stdio \(error)") }
    }
    // VM stop precedes client close, so a pending guest RPC cannot keep native RAM alive.
    if let machine = manager.instance {
      do { try await machine.stop() } catch { cleanup.append("native-stop \(error)") }
    }
    if let agent {
      do { try await agent.close() } catch { cleanup.append("agent-close \(error)") }
    }
    do { try await group.shutdownGracefully() } catch { cleanup.append("group-join \(error)") }
    if let native = manager.instance?.result {
      try native.write(to: output.appending(path: "native.json"), options: .withoutOverwriting)
    }
    let checked = primary.isEmpty && cleanup.isEmpty && deleted && exitCode == scenario.expectedExit
    let result: [String: Any] = [
      "checked": checked, "primaryError": primary, "cleanupErrors": cleanup,
      "rootProcessRefusal": rootRefusal, "pid": pid, "exitCode": exitCode,
      "scenario": scenario.rawValue, "diagnostics": diagnostics,
      "deleted": deleted, "transcript": transcript, "physicalReleasedBytes": NSNull(),
      "scope": "G0 trusted service-container protocol/lifecycle; not autonomous RAM qualification",
    ]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appending(path: "result.json"), options: .withoutOverwriting)
    guard checked else { throw Failure.check(primary + cleanup.joined(separator: "; ")) }
    print("MONITOR_SERVICE_CHECK_PASS")
  }

  private static func validate(_ line: String, sequence: Int?, maximum: UInt64) throws {
    let words = line.split(separator: " ")
    let start = sequence == nil ? 1 : 2
    guard words.count == start + 2,
      words[0] == (sequence == nil ? "MEMORY_READY" : "MEMORY_OK"),
      sequence.map({ words[1] == Substring(String($0)) }) ?? true,
      let total = UInt64(words[start]), total > 0, total <= maximum,
      let available = UInt64(words[start + 1]), available <= total
    else { throw Failure.check("memory frame") }
  }
}
