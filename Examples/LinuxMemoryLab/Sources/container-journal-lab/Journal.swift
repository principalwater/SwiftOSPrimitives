import ContainerizationEXT4
import Darwin
import Foundation

@main private struct Journal {
  enum Failure: Error { case arguments, geometry }
  static func main() async {
    do { try await run() } catch {
      print("JOURNAL_FAIL \(error)")
      exit(1)
    }
  }
  static func run() async throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count == 1 else { throw Failure.arguments }
    let root = URL(filePath: args[0], directoryHint: .isDirectory)
    guard root.standardizedFileURL == root, root.resolvingSymlinksInPath() == root,
      root.path.hasPrefix("/Volumes/t7_ssd/macserve-research/")
    else { throw Failure.arguments }
    var info = stat()
    guard lstat(root.path, &info) == 0, info.st_uid == getuid(),
      info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0
    else { throw Failure.arguments }
    let ownerURL = root.appending(path: "OWNER.json")
    let ownerFD = open(ownerURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard ownerFD >= 0 else { throw Failure.arguments }
    let handle = FileHandle(fileDescriptor: ownerFD, closeOnDealloc: true)
    defer { try? handle.close() }
    guard fstat(ownerFD, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == getuid(), info.st_size > 0, info.st_size <= 4096,
      let bytes = try handle.read(upToCount: 4097), bytes.count == info.st_size,
      let owner = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
      owner["root"] as? String == root.path, owner["uid"] as? Int == Int(getuid()),
      owner["purpose"] as? String == "isolated-container-continuous-G21"
    else { throw Failure.arguments }
    let source = root.appending(path: "artifacts/clickhouse-base.ext4")
    let archive = root.appending(path: "build/tmp/journal-rootfs.tar")
    let target = root.appending(path: "artifacts/clickhouse-journal-base.ext4")
    guard source.resolvingSymlinksInPath() == source,
      lstat(source.path, &info) == 0, info.st_uid == getuid(), info.st_nlink == 1,
      info.st_mode & S_IFMT == S_IFREG, info.st_size == 8 << 30,
      !FileManager.default.fileExists(atPath: archive.path),
      !FileManager.default.fileExists(atPath: target.path)
    else { throw Failure.arguments }
    let reader = try EXT4.EXT4Reader(blockDevice: .init(source.path))
    guard reader.superBlock.featureCompat & 4 == 0 else { throw Failure.geometry }
    try reader.export(archive: .init(archive.path))
    let formatter = try EXT4.Formatter(
      .init(target.path), minDiskSize: (8 << 30) - (64 << 20),
      journal: .init(size: 64 << 20, defaultMode: .ordered))
    try await formatter.unpack(source: archive, compression: .none)
    try formatter.close()
    let result = try EXT4.EXT4Reader(blockDevice: .init(target.path))
    guard result.superBlock.featureCompat & 4 != 0, result.superBlock.journalInum == 8,
      lstat(target.path, &info) == 0, info.st_size == 8 << 30
    else { throw Failure.geometry }
    print("JOURNAL_READY bytes=\(info.st_size) internalInode=8 mode=ordered")
  }
}
