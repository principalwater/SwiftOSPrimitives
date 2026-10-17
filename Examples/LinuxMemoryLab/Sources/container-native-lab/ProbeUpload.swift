import Containerization
import Darwin
import Foundation

extension Lab {
  /// Sends the exact bounded, regular guest binary to a fresh caller-owned path.
  static func uploadProbe(_ source: URL, path: String, agent: some VirtualMachineAgent) async throws
    -> Int
  {
    let descriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw Failure.check("probe open \(errno)") }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var before = stat()
    guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
      before.st_size > 0, before.st_size <= 8 << 20, before.st_nlink == 1
    else { throw Failure.check("probe geometry") }
    var written = 0
    while let bytes = try handle.read(upToCount: 65536), !bytes.isEmpty {
      guard bytes.count <= (8 << 20) - written else { throw Failure.check("probe size") }
      try await agent.writeFile(
        path: path, data: bytes, flags: .init(create: written == 0, append: written != 0),
        mode: 0o700)
      written += bytes.count
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0, written == before.st_size,
      after.st_size == before.st_size,
      after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
      after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
      after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
      after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec
    else { throw Failure.check("probe changed during upload") }
    return written
  }
}
