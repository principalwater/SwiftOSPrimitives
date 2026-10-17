#if os(Linux)
  #if canImport(Musl)
    import Musl
  #else
    import Glibc
  #endif
#endif

/// Admission for the dedicated trusted service; diagnostic exec probes do not use it.
package enum GuestMemoryService {
  enum Failure: Error, Equatable {
    case identity, privileges, descriptors, readOnlyFilesystem
    case filesystem(String, Int32)
  }

  /// Kernel status fields, not a reflection of the requested OCI configuration.
  static func validateStatus(_ bytes: UnsafeBufferPointer<UInt8>) throws {
    let required = [
      ("CapInh:", "0000000000000000"), ("CapPrm:", "0000000000000000"),
      ("CapEff:", "0000000000000000"), ("CapBnd:", "0000000000000000"),
      ("CapAmb:", "0000000000000000"), ("NoNewPrivs:", "1"), ("Threads:", "1"),
    ]
    let lines = String(decoding: bytes, as: UTF8.self).split(separator: "\n")
    for (key, value) in required {
      let matches = lines.filter { $0.hasPrefix(key) }
      guard matches.count == 1 else { throw Failure.privileges }
      let fields = matches[0].split(whereSeparator: { $0 == " " || $0 == "\t" })
      guard fields.count == 2, fields[0] == key, fields[1] == value else {
        throw Failure.privileges
      }
    }
  }

  #if os(Linux)
    /// Withholds READY unless the process really is isolated PID1/root with no capabilities,
    /// no privilege escalation, one thread, protected proc mounts and exactly its three IO fds.
    package static func validate() throws {
      guard getpid() == 1, getuid() == 0, geteuid() == 0, getgid() == 0, getegid() == 0 else {
        throw Failure.identity
      }
      try GuestMemory.withProcBytes(at: "/proc/self/status", validateStatus)
      for path in ["/", "/proc/sys", "/proc/sysrq-trigger", "/proc/irq", "/proc/bus", "/proc/fs"] {
        var filesystem = statvfs()
        if statvfs(path, &filesystem) != 0 {
          let failure = errno
          // Optional kernel proc interfaces may be absent; every present path must be read-only.
          if failure == ENOENT, path != "/", path != "/proc/sys" { continue }
          throw Failure.filesystem(path, failure)
        }
        guard filesystem.f_flag & UInt(ST_RDONLY) != 0 else { throw Failure.readOnlyFilesystem }
      }
      try validateDescriptors()
    }

    private static func validateDescriptors() throws {
      for fd: Int32 in 0...2 {
        guard fcntl(fd, F_GETFD) >= 0 else { throw Failure.descriptors }
      }
      guard let directory = opendir("/proc/self/fd") else {
        throw GuestMemoryFailure.system(errno)
      }
      var owned = true
      defer { if owned { _ = closedir(directory) } }
      let listingFD = dirfd(directory)
      guard listingFD >= 0 else { throw GuestMemoryFailure.system(errno) }
      var entries = 0
      while true {
        errno = 0
        guard let entry = readdir(directory) else {
          guard errno == 0 else { throw GuestMemoryFailure.system(errno) }
          break
        }
        entries += 1
        guard entries <= 6 else { throw Failure.descriptors }
        let name = try withUnsafeBytes(of: entry.pointee.d_name) { bytes in
          let text = bytes.prefix { $0 != 0 }
          guard text.count < bytes.count else { throw Failure.descriptors }
          return String(decoding: text, as: UTF8.self)
        }
        if name == "." || name == ".." { continue }
        guard let fd = Int32(name), (0...2).contains(fd) || fd == listingFD else {
          throw Failure.descriptors
        }
      }
      let result = closedir(directory)
      owned = false
      guard result == 0 else { throw GuestMemoryFailure.system(errno) }
    }
  #endif
}
