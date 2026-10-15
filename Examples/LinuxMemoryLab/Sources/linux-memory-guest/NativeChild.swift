#if os(Linux)
  import Musl

  func monotonic() throws -> UInt64 {
    var stamp = timespec()
    guard clock_gettime(CLOCK_MONOTONIC, &stamp) == 0, stamp.tv_sec >= 0 else {
      throw NativeFailure.system(errno)
    }
    return UInt64(stamp.tv_sec) * 1_000_000_000 + UInt64(stamp.tv_nsec)
  }
  enum NativeFailure: Error {
    case system(Int32)
    case output, deadline
  }
  func nativeWrite(_ descriptor: Int32, _ bytes: [UInt8]) throws {
    try bytes.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw NativeFailure.system(errno) }
        offset += count
      }
    }
  }
  func directory(_ path: String) throws {
    if mkdir(path, 0o700) == 0 { return }
    var metadata = stat()
    guard errno == EEXIST, lstat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else {
      throw NativeFailure.system(errno)
    }
  }
  func writeFile(_ path: String, _ text: String) throws {
    let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw NativeFailure.system(errno) }
    defer { _ = Musl.close(descriptor) }
    try nativeWrite(descriptor, Array(text.utf8))
  }
  func readFile(_ path: String) throws -> String {
    let descriptor = open(path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { throw NativeFailure.system(errno) }
    defer { _ = Musl.close(descriptor) }
    var bytes = [UInt8](repeating: 0, count: 4097)
    var total = 0
    while total < bytes.count {
      let count = bytes.withUnsafeMutableBytes {
        read(descriptor, $0.baseAddress! + total, $0.count - total)
      }
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else { throw NativeFailure.system(errno) }
      if count == 0 { break }
      total += count
    }
    guard total <= 4096 else { throw NativeFailure.output }
    while total > 0, bytes[total - 1] == 10 || bytes[total - 1] == 13 { total -= 1 }
    return String(decoding: bytes.prefix(total), as: UTF8.self)
  }

  // Own child only, single waitpid owner, explicit bounded join and no watchdog fork.
  final class NativeChild {
    let processIdentifier: pid_t
    private var status: Int32?
    var terminationStatus: Int32 {
      guard let status else { return -999 }
      return status & 0x7f == 0 ? (status >> 8) & 255 : 128 + (status & 0x7f)
    }
    init(arguments: [String], path: String) throws {
      let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
      guard descriptor >= 0 else { throw NativeFailure.system(errno) }
      defer { _ = Musl.close(descriptor) }
      var actions = posix_spawn_file_actions_t()
      var result = posix_spawn_file_actions_init(&actions)
      guard result == 0 else { throw NativeFailure.system(result) }
      defer { posix_spawn_file_actions_destroy(&actions) }
      result = posix_spawn_file_actions_adddup2(&actions, descriptor, 1)
      guard result == 0 else { throw NativeFailure.system(result) }
      result = posix_spawn_file_actions_adddup2(&actions, descriptor, 2)
      guard result == 0 else { throw NativeFailure.system(result) }
      result = posix_spawn_file_actions_addclose(&actions, descriptor)
      guard result == 0 else { throw NativeFailure.system(result) }
      result = posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
      guard result == 0 else { throw NativeFailure.system(result) }
      let strings = ["/usr/bin/clickhouse"] + arguments
      let environment = [
        "PATH=/usr/bin:/bin", "HOME=/tmp", "TZ=UTC", "CLICKHOUSE_WATCHDOG_ENABLE=0",
      ]
      var argv = strings.map { strdup($0) }
      var env = environment.map { strdup($0) }
      defer {
        for pointer in argv { free(pointer) }
        for pointer in env { free(pointer) }
      }
      guard argv.allSatisfy({ $0 != nil }), env.allSatisfy({ $0 != nil }) else {
        throw NativeFailure.system(ENOMEM)
      }
      argv.append(nil)
      env.append(nil)
      var pid: pid_t = -1
      result = posix_spawn(&pid, "/usr/bin/clickhouse", &actions, nil, &argv, &env)
      guard result == 0, pid > 1 else { throw NativeFailure.system(result) }
      processIdentifier = pid
    }
    func poll() throws -> Bool {
      if status != nil { return false }
      var value: Int32 = 0
      let result = waitpid(processIdentifier, &value, WNOHANG)
      if result == processIdentifier {
        status = value
        return false
      }
      if result == 0 || result < 0 && errno == EINTR { return true }
      throw NativeFailure.system(errno)
    }
    func signal(_ value: Int32) throws {
      guard try poll() else { return }
      guard kill(processIdentifier, value) == 0 else { throw NativeFailure.system(errno) }
    }
    func join(seconds: Int) throws {
      let deadline = try monotonic() + UInt64(seconds) * 1_000_000_000
      while try poll(), try monotonic() < deadline { usleep(10000) }
      guard try !poll() else { throw NativeFailure.deadline }
    }
  }
#endif
