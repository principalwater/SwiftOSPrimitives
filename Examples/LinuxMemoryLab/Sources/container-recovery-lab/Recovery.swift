import Darwin
import Foundation

@main private struct Recovery {
  enum Failure: Error {
    case arguments
    case native(String, Int32)
    case deadline, evidence
  }
  static func main() {
    do { try run() } catch {
      print("RECOVERY_FAIL \(error)")
      exit(1)
    }
  }
  static func run() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count == 6 else { throw Failure.arguments }
    let output = URL(filePath: args[4])
    let root = output.deletingLastPathComponent().deletingLastPathComponent()
    var directoryInfo = stat()
    guard lstat(root.path, &directoryInfo) == 0, directoryInfo.st_mode & S_IFMT == S_IFDIR,
      directoryInfo.st_uid == getuid(), directoryInfo.st_mode & 0o077 == 0,
      output.standardizedFileURL == output, output.resolvingSymlinksInPath() == output,
      output.deletingLastPathComponent().lastPathComponent == "results"
    else { throw Failure.arguments }
    let marker = root.appending(path: "OWNER.json")
    let fd = open(marker.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw Failure.arguments }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
      info.st_nlink == 1, info.st_size > 0, info.st_size <= 4096,
      let bytes = try handle.read(upToCount: 4097), bytes.count == info.st_size
    else { throw Failure.arguments }
    let owner = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
    guard owner?["root"] as? String == root.path, owner?["uid"] as? Int == Int(getuid()),
      owner?["purpose"] as? String == "isolated-container-adaptive-G20"
    else { throw Failure.arguments }
    for (index, directory) in [
      (0, "artifacts"), (1, "inputs"), (2, "artifacts"), (3, "artifacts"), (5, "artifacts"),
    ] {
      let file = URL(filePath: args[index])
      var metadata = stat()
      guard file.path == args[index], file.standardizedFileURL == file,
        file.resolvingSymlinksInPath() == file,
        file.deletingLastPathComponent().path == root.appending(path: directory).path,
        lstat(file.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
        metadata.st_uid == getuid(), metadata.st_nlink == 1
      else { throw Failure.native("canonical-input-\(index)", EINVAL) }
    }

    let diskHandle = try FileHandle(forReadingFrom: URL(filePath: args[3]))
    defer { try? diskHandle.close() }
    try diskHandle.seek(toOffset: 1024)
    guard let superblock = try diskHandle.read(upToCount: 1024), superblock.count == 1024,
      superblock.withUnsafeBytes({
        $0.loadUnaligned(fromByteOffset: 56, as: UInt16.self).littleEndian
      }) == 0xef53,
      superblock.withUnsafeBytes({
        $0.loadUnaligned(fromByteOffset: 92, as: UInt32.self).littleEndian
      }) & 4 != 0,
      superblock.withUnsafeBytes({
        $0.loadUnaligned(fromByteOffset: 224, as: UInt32.self).littleEndian
      }) == 8
    else { throw Failure.native("recovery-requires-internal-ext4-journal", EINVAL) }
    try FileManager.default.createDirectory(
      at: output, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    func record(_ name: String, _ fields: [String: Any]) throws {
      let path = output.appending(path: name + ".json")
      try JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys])
        .write(to: path, options: .withoutOverwriting)
      let handle = try FileHandle(forWritingTo: path)
      try handle.synchronize()
      try handle.close()
      let directory = open(output.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
      guard directory >= 0 else { throw Failure.native("journal-directory", errno) }
      defer { _ = close(directory) }
      guard fsync(directory) == 0 else { throw Failure.native("journal-sync", errno) }
    }
    var leaseWriter: Int32 = -1
    func closeLease() throws {
      guard leaseWriter >= 0 else { return }
      let old = leaseWriter
      leaseWriter = -1
      guard Darwin.close(old) == 0 else { throw Failure.native("lease-close", errno) }
    }
    func launch(_ mode: String, _ directory: URL) throws -> pid_t {
      guard leaseWriter < 0 else { throw Failure.evidence }
      var pipeFD: [Int32] = [-1, -1]
      guard pipe(&pipeFD) == 0 else { throw Failure.native("lease-pipe", errno) }
      var retained = false
      defer {
        _ = Darwin.close(pipeFD[0])
        if !retained { _ = Darwin.close(pipeFD[1]) }
      }
      for fd in pipeFD {
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
          throw Failure.native("lease-cloexec", errno)
        }
      }
      var pressure: Int32 = 0
      var size = MemoryLayout<Int32>.size
      guard sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0) == 0,
        size == MemoryLayout<Int32>.size, [1, 2].contains(pressure)
      else { throw Failure.evidence }
      var actions: posix_spawn_file_actions_t?
      var attributes: posix_spawnattr_t?
      let actionCode = posix_spawn_file_actions_init(&actions)
      guard actionCode == 0 else { throw Failure.native("spawn-actions", actionCode) }
      defer { posix_spawn_file_actions_destroy(&actions) }
      let attributeCode = posix_spawnattr_init(&attributes)
      guard attributeCode == 0 else { throw Failure.native("spawn-attributes-init", attributeCode) }
      defer { posix_spawnattr_destroy(&attributes) }
      let log = output.appending(path: mode + ".log").path
      for (fd, path, flags) in [
        (Int32(0), "/dev/null", O_RDONLY), (Int32(1), log, O_WRONLY | O_CREAT | O_EXCL),
      ] {
        let code = posix_spawn_file_actions_addopen(&actions, fd, path, flags, 0o600)
        guard code == 0 else { throw Failure.native("spawn-open", code) }
      }
      guard posix_spawn_file_actions_adddup2(&actions, pipeFD[0], 3) == 0,
        posix_spawn_file_actions_adddup2(&actions, 1, 2) == 0,
        posix_spawnattr_setpgroup(&attributes, 0) == 0,
        posix_spawnattr_setflags(
          &attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0
      else { throw Failure.native("spawn-attributes", errno) }
      let command = [args[0], args[1], args[2], args[3], directory.path, mode, args[5]]
      var argv = command.map { strdup($0) } + [nil]
      var environment = ProcessInfo.processInfo.environment.filter {
        ["PATH", "TMPDIR", "LANG", "LC_ALL", "SWIFTOS_LAB_CPUS"].contains($0.key)
      }
      environment["SWIFTOS_LAB_PARENT"] = String(getpid())
      environment["SWIFTOS_LAB_LEASE_FD"] = "3"
      var env = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
      defer {
        for value in argv { free(value) }
        for value in env { free(value) }
      }
      guard argv.dropLast().allSatisfy({ $0 != nil }), env.dropLast().allSatisfy({ $0 != nil })
      else { throw Failure.evidence }
      var pid: pid_t = 0
      let code = posix_spawn(&pid, args[0], &actions, &attributes, &argv, &env)
      guard code == 0, pid > 0 else { throw Failure.native("spawn", code) }
      leaseWriter = pipeFD[1]
      retained = true
      return pid
    }
    func poll(_ pid: pid_t) throws -> Int32? {
      var status: Int32 = 0
      let result = waitpid(pid, &status, WNOHANG)
      if result == 0 { return nil }
      if result < 0, errno == EINTR { return nil }
      guard result == pid else { throw Failure.native("waitpid", errno) }
      return status
    }
    func wait(_ pid: pid_t, seconds: Int) throws -> Int32 {
      let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
      while ContinuousClock.now < deadline {
        if let status = try poll(pid) { return status }
        usleep(10000)
      }
      throw Failure.deadline
    }
    func requireGroupGone(_ pid: pid_t) throws {
      let deadline = ContinuousClock.now.advanced(by: .seconds(5))
      while kill(-pid, 0) == 0 || errno != ESRCH {
        guard ContinuousClock.now < deadline else { throw Failure.evidence }
        usleep(10000)
      }
    }
    var child: pid_t?
    do {
      let first = output.appending(path: "attempt-1")
      let pid = try launch("crash", first)
      child = pid
      try record("01-started", ["pid": pid, "attempt": 1])
      let ready = first.appending(path: "CRASH_READY.json")
      let deadline = ContinuousClock.now.advanced(by: .seconds(90))
      while !FileManager.default.fileExists(atPath: ready.path) {
        if let status = try poll(pid) {
          child = nil
          throw Failure.native("early-exit", status)
        }
        guard ContinuousClock.now < deadline else { throw Failure.deadline }
        usleep(10000)
      }
      let data = try Data(contentsOf: ready)
      guard data.count <= 8192,
        let evidence = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        evidence["pid"] as? Int == Int(pid), evidence["rows"] as? Int == 400000,
        evidence["activeQuery"] as? Bool == true, evidence["durableInserts"] as? Bool == true
      else { throw Failure.evidence }
      guard try poll(pid) == nil else {
        child = nil
        throw Failure.evidence
      }
      guard kill(-pid, SIGKILL) == 0 else { throw Failure.native("kill", errno) }
      let status = try wait(pid, seconds: 5)
      child = nil
      try closeLease()
      try requireGroupGone(pid)
      guard status & 0x7f == SIGKILL else { throw Failure.native("not-sigkill", status) }
      try record("02-reaped", ["pid": pid, "status": status, "signal": SIGKILL, "ready": evidence])
      let second = output.appending(path: "attempt-2")
      let replacement = try launch("recover", second)
      child = replacement
      try record("03-restarted", ["pid": replacement, "attempt": 2, "previousReaped": true])
      let restarted = try wait(replacement, seconds: 120)
      child = nil
      try closeLease()
      try requireGroupGone(replacement)
      guard restarted == 0 else { throw Failure.native("replacement-exit", restarted) }
      let result =
        try JSONSerialization.jsonObject(
          with: Data(contentsOf: second.appending(path: "result.json"))) as? [String: Any]
      guard result?["checked"] as? Bool == true else { throw Failure.evidence }
      try record(
        "04-complete",
        [
          "attempts": 2, "sigkillReaped": true, "persistentIntegrity": true,
          "replacementExit": restarted,
        ])
      print("RECOVERY_PASS")
    } catch {
      if let pid = child {
        do {
          if try poll(pid) == nil {
            guard kill(-pid, SIGKILL) == 0 else { throw Failure.native("cleanup-kill", errno) }
            _ = try wait(pid, seconds: 5)
            try requireGroupGone(pid)
          }
        } catch { print("RECOVERY_CLEANUP_FAIL \(error)") }
      }
      do { try closeLease() } catch { print("RECOVERY_LEASE_CLOSE_FAIL \(error)") }
      throw error
    }
  }
}
