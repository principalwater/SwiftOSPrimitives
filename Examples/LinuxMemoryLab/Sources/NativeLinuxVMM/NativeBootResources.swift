import Darwin
import Foundation
import PageMemory
import Synchronization

/// Pinned boot inputs from one already admitted private directory, independent of its pathname.
/// The caller owns import/provenance and its directory grant. This does not adopt external data.
/// Kernel/initfs/rootfs names are fixed; each boot creates a new, never overwritten console.
public final class NativeBootResources: Sendable {
  public enum Failure: Error {
    case unsafeFile, invalidKernel, alreadyClaimed
    case system(Int32)
  }
  public let id: UUID
  /// Use this exact opaque source in the Containerization root block mount.
  public var mountSource: String { "native-capability:" + id.uuidString }
  public var consoleName: String { "console-" + id.uuidString + ".log" }
  private struct State {
    var kernel: Data?
    var initfs: Int32
    var rootfs: Int32
    var console: Int32
    var claimed = false
    var retired = false
    var retirementError: Int32?
  }
  private let state: Mutex<State>

  /// Opens only fixed children with openat/O_NOFOLLOW; retains independent native descriptors.
  /// Releasing the caller's directory descriptor or renaming that directory is safe afterward.
  public init(directoryDescriptor: Int32) throws {
    let id = UUID()
    let directory = fcntl(directoryDescriptor, F_DUPFD_CLOEXEC, 10)
    guard directory >= 0 else { throw Failure.system(errno) }
    defer { Darwin.close(directory) }
    var info = stat()
    guard fstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      info.st_uid == getuid(), info.st_mode & 0o077 == 0
    else { throw Failure.unsafeFile }
    try Self.validateAccess(directory)
    var opened: [Int32] = []
    var retained = false
    defer { if !retained { for fd in opened { Darwin.close(fd) } } }
    func openInput(_ name: String, writable: Bool, maximum: UInt64) throws -> (Int32, stat) {
      let fd = openat(
        directory, name,
        (writable ? O_RDWR : O_RDONLY) | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
      guard fd >= 0 else { throw Failure.system(errno) }
      opened.append(fd)
      var value = stat()
      guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
        value.st_uid == getuid(), value.st_nlink == 1, value.st_mode & 0o077 == 0,
        value.st_size > 0, UInt64(value.st_size) <= maximum,
        flock(fd, (writable ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0
      else { throw Failure.unsafeFile }
      try Self.validateAccess(fd)
      return (fd, value)
    }
    let (kernelFD, _) = try openInput("kernel", writable: false, maximum: 64 << 20)
    let image = try Self.kernelImage(descriptor: kernelFD)
    let (initfs, initInfo) = try openInput("initfs.ext4", writable: false, maximum: 512 << 20)
    let (rootfs, rootInfo) = try openInput("rootfs.ext4", writable: true, maximum: 1 << 40)
    guard initInfo.st_size % 512 == 0, rootInfo.st_size % 512 == 0,
      fcntl(initfs, F_NOCACHE, 1) == 0, fcntl(rootfs, F_NOCACHE, 1) == 0
    else { throw Failure.unsafeFile }
    let console = openat(
      directory, "console-" + id.uuidString + ".log",
      O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard console >= 0 else { throw Failure.system(errno) }
    opened.append(console)
    try Self.validateAccess(console)
    guard fsync(directory) == 0 else { throw Failure.system(errno) }
    self.id = id
    state = Mutex(State(kernel: image, initfs: initfs, rootfs: rootfs, console: console))
    // The kernel is an immutable bounded snapshot, not a surviving host-file mapping.
    Darwin.close(kernelFD)
    retained = true
  }

  deinit { try? retire() }

  func claim() throws {
    try state.withLock {
      guard !$0.claimed, !$0.retired else { throw Failure.alreadyClaimed }
      $0.claimed = true
    }
  }
  /// Transfer the one-shot snapshot to boot; the admission owner must not retain a second image.
  func takeKernel() throws -> Data {
    try state.withLock {
      guard !$0.retired, let image = $0.kernel else { throw Failure.alreadyClaimed }
      $0.kernel = nil
      return image
    }
  }
  func duplicateDisk(readOnly: Bool) throws -> Int32 {
    try state.withLock { try duplicate(readOnly ? $0.initfs : $0.rootfs) }
  }
  func duplicateConsole() throws -> Int32 { try state.withLock { try duplicate($0.console) } }
  private func duplicate(_ descriptor: Int32) throws -> Int32 {
    guard descriptor >= 0 else { throw Failure.alreadyClaimed }
    try Self.validateAccess(descriptor)
    let fd = fcntl(descriptor, F_DUPFD_CLOEXEC, 10)
    guard fd >= 0 else { throw Failure.system(errno) }
    return fd
  }

  /// Called only after native teardown or before any worker starts. Duplication and retirement
  /// share one lock; outstanding disk attachments keep their own independent descriptors.
  func retire() throws {
    try state.withLock { value in
      if !value.retired {
        value.retired = true
        value.kernel = nil
        for fd in [value.initfs, value.rootfs, value.console] {
          if Darwin.close(fd) != 0, value.retirementError == nil { value.retirementError = errno }
        }
        value.initfs = -1
        value.rootfs = -1
        value.console = -1
      }
      if let error = value.retirementError { throw Failure.system(error) }
    }
  }

  private static func validateAccess(_ descriptor: Int32) throws {
    do { try DarwinFileAuthority.validate(descriptor) } catch { throw Failure.unsafeFile }
  }

  static func kernelImage(at path: String) throws -> Data {
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw Failure.system(errno) }
    defer { Darwin.close(descriptor) }
    return try kernelImage(descriptor: descriptor)
  }

  private static func kernelImage(descriptor: Int32) throws -> Data {
    var before = stat()
    guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
      before.st_size >= 64, before.st_size <= 64 << 20
    else { throw Failure.invalidKernel }
    var image = Data(count: Int(before.st_size))
    try image.withUnsafeMutableBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = pread(
          descriptor, bytes.baseAddress! + offset, bytes.count - offset, off_t(offset))
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw Failure.system(count == 0 ? EIO : errno) }
        offset += count
      }
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0, after.st_size == before.st_size,
      after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
      after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
      after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
      after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec,
      image[56..<60].elementsEqual([0x41, 0x52, 0x4d, 0x64])
    else { throw Failure.invalidKernel }
    return image
  }
}
