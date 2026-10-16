import Darwin
import Foundation

// Synchronous pread/pwrite only: no outstanding I/O can retain a guest RAM pointer.
final class BlockDevice {
  let transport: VirtioMMIO
  let readOnly: Bool
  let thread = pthread_self()
  private var descriptor: Int32
  let bytes: UInt64
  var written: UInt64 = 0
  init(path: String, readOnly: Bool = false, interrupt: UInt32 = 36) throws {
    self.readOnly = readOnly
    transport = VirtioMMIO(
      identity: 2, features: (1 << 9) | (1 << 1) | (1 << 2) | (readOnly ? 1 << 5 : 0),
      interrupt: interrupt)
    let file = URL(filePath: path)
    let root = file.deletingLastPathComponent().deletingLastPathComponent()
    let marker = root.appending(path: "OWNER.json")
    let attributes = try FileManager.default.attributesOfItem(atPath: marker.path)
    guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 4096,
      file.resolvingSymlinksInPath() == file,
      file.lastPathComponent.hasPrefix("clickhouse-run-")
        || readOnly && file.lastPathComponent == "initfs.ext4", file.pathExtension == "ext4",
      file.deletingLastPathComponent().lastPathComponent == "artifacts"
    else { throw DeviceFailure.geometry }
    let owner = try JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any]
    guard owner?["root"] as? String == root.path,
      owner?["purpose"] as? String == "isolated-container-adaptive-G20",
      owner?["uid"] as? Int == Int(getuid())
    else { throw DeviceFailure.geometry }
    descriptor = open(path, (readOnly ? O_RDONLY : O_RDWR) | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw DeviceFailure.native(errno) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_nlink == 1,
      readOnly
        ? metadata.st_size > 0 && metadata.st_size <= 512 << 20 : metadata.st_size == 8 << 30,
      metadata.st_uid == getuid(), flock(descriptor, LOCK_EX | LOCK_NB) == 0,
      fcntl(descriptor, F_NOCACHE, 1) == 0
    else {
      _ = Darwin.close(descriptor)
      throw DeviceFailure.geometry
    }
    bytes = UInt64(metadata.st_size)
  }
  func config() -> Data {
    var sectors = (bytes / 512).littleEndian
    var bytes = Data(bytes: &sectors, count: 8)
    for item: UInt32 in [65536, 14] {
      var value = item.littleEndian
      withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) }
    }
    return bytes
  }
  func process(
    _ buffers: [GuestBuffer],
    memory: (UInt64, Int) throws -> UnsafeMutableRawPointer
  ) throws -> UInt32 {
    guard pthread_equal(thread, pthread_self()) != 0 else { throw DeviceFailure.request }
    guard descriptor >= 0, buffers.count >= 2, !buffers[0].writable, buffers[0].size == 16,
      let status = buffers.last, status.writable, status.size == 1
    else { throw DeviceFailure.request }
    let header = try memory(buffers[0].address, 16)
    let kind = header.loadUnaligned(as: UInt32.self).littleEndian
    let sector = header.loadUnaligned(fromByteOffset: 8, as: UInt64.self).littleEndian
    let payload = Array(buffers.dropFirst().dropLast())
    let total = payload.reduce(0) { $0 + $1.size }
    if kind != 0 && kind != 1 && kind != 4 {
      try memory(status.address, 1).storeBytes(of: UInt8(2), as: UInt8.self)
      return 1
    }
    guard total <= 1 << 20, total % 512 == 0,
      sector <= bytes / 512, UInt64(total) <= bytes - sector * 512
    else {
      throw DeviceFailure.request
    }
    let statusPointer = try memory(status.address, 1)
    // A legal physical segment can cross two separately owned host allocations.
    var spans: [[UnsafeMutableRawBufferPointer]] = []
    for buffer in payload {
      guard buffer.size <= 65536, payload.count <= 14,
        kind > 1 || buffer.writable == (kind == 0)
      else { throw DeviceFailure.request }
      var address = buffer.address
      var remaining = buffer.size
      var pieces: [UnsafeMutableRawBufferPointer] = []
      while remaining > 0 {
        let count = min(remaining, MemoryDevice.block - Int(address % UInt64(MemoryDevice.block)))
        pieces.append(
          UnsafeMutableRawBufferPointer(start: try memory(address, count), count: count))
        address += UInt64(count)
        remaining -= count
      }
      spans.append(pieces)
    }
    var result: UInt8 = 0
    var completed: UInt32 = 1
    if kind == 0 || kind == 1 {
      guard total > 0 else { throw DeviceFailure.request }
      if kind == 1 {
        guard !readOnly else { throw DeviceFailure.request }
        guard UInt64(total) <= (512 << 20) - written else { throw DeviceFailure.request }
        written += UInt64(total)
      }
      var offset = sector * 512
      for pieces in spans {
        for piece in pieces {
          var done = 0
          while done < piece.count {
            let count =
              kind == 0
              ? pread(descriptor, piece.baseAddress! + done, piece.count - done, off_t(offset))
              : pwrite(descriptor, piece.baseAddress! + done, piece.count - done, off_t(offset))
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw DeviceFailure.native(errno) }
            done += count
            offset += UInt64(count)
          }
        }
      }
      if kind == 0 { completed += UInt32(total) }
    } else if kind == 4 {
      guard total == 0 else { throw DeviceFailure.request }
      guard readOnly || fcntl(descriptor, F_FULLFSYNC) == 0 else {
        throw DeviceFailure.native(errno)
      }
    } else {
      result = 2
    }
    statusPointer.storeBytes(of: result, as: UInt8.self)
    return completed
  }
  func close() throws {
    guard pthread_equal(thread, pthread_self()) != 0 else { throw DeviceFailure.request }
    guard descriptor >= 0 else { return }
    let old = descriptor
    descriptor = -1
    guard Darwin.close(old) == 0 else { throw DeviceFailure.native(errno) }
  }
}
