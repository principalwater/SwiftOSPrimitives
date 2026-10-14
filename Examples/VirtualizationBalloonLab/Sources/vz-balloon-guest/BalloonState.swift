import _Volatile

#if canImport(Musl)
  import Musl
#else
  import Glibc
#endif

private enum BalloonError: Error { case topology, config, mapping, changed }

// Read-only modern virtio PCI device config. Never touches queues, ISR or driver ownership.
struct BalloonState: ~Copyable {
  private let mapping: UnsafeMutableRawPointer?
  private let length: Int
  private let offset: Int

  init() throws {
    let result = try Self.openMapping()
    mapping = result.0
    length = result.1
    offset = result.2
  }

  private static func openMapping() throws -> (UnsafeMutableRawPointer?, Int, Int) {
    guard let directory = opendir("/sys/bus/pci/devices") else { throw BalloonError.topology }
    defer { _ = closedir(directory) }
    var chosen: String?
    var count = 0
    while let entry = readdir(directory) {
      count += 1
      guard count <= 64 else { throw BalloonError.topology }
      let name = withUnsafePointer(to: entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
      }
      guard !name.hasPrefix(".") else { continue }
      let path = "/sys/bus/pci/devices/" + name
      let fd = open(path + "/config", O_RDONLY | O_CLOEXEC)
      guard fd >= 0 else { throw BalloonError.config }
      var identity = [UInt8](repeating: 0, count: 4)
      let count = pread(fd, &identity, 4, 0)
      _ = close(fd)
      guard count == 4 else { throw BalloonError.config }
      if identity == [0xf4, 0x1a, 0x45, 0x10] {
        guard chosen == nil else { throw BalloonError.topology }
        chosen = path
      }
    }
    guard let chosen else {
      return (nil, 0, 0)
    }
    let fd = open(chosen + "/config", O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { throw BalloonError.config }
    defer { _ = close(fd) }
    var config = [UInt8](repeating: 0, count: 256)
    guard pread(fd, &config, config.count, 0) == config.count else { throw BalloonError.config }
    func word(_ index: Int) -> UInt32 {
      UInt32(config[index]) | UInt32(config[index + 1]) << 8 | UInt32(config[index + 2]) << 16
        | UInt32(config[index + 3]) << 24
    }
    var cap = Int(config[0x34])
    var visited = [Bool](repeating: false, count: 256)
    var selected: (bar: UInt8, offset: UInt32, length: UInt32)?
    while cap != 0 {
      guard cap >= 0x40, cap <= 0xf0, cap % 4 == 0, !visited[cap] else {
        throw BalloonError.config
      }
      visited[cap] = true
      if config[cap] == 9, config[cap + 3] == 4 {
        guard config[cap + 2] >= 16, config[cap + 4] < 6, selected == nil else {
          throw BalloonError.config
        }
        selected = (config[cap + 4], word(cap + 8), word(cap + 12))
      }
      cap = Int(config[cap + 1])
    }
    guard let selected, selected.length >= 8, selected.offset % 4 == 0 else {
      throw BalloonError.config
    }
    let size = sysconf(Int32(_SC_PAGESIZE))
    guard size == 4096 else { throw BalloonError.mapping }
    let base = Int(selected.offset) / size * size
    let offset = Int(selected.offset) - base
    let length = (offset + 8 + size - 1) / size * size
    let resource = open(chosen + "/resource\(selected.bar)", O_RDONLY | O_CLOEXEC | O_SYNC)
    guard resource >= 0 else { throw BalloonError.mapping }
    defer { _ = close(resource) }
    var info = stat()
    guard fstat(resource, &info) == 0, info.st_size >= base + length else {
      throw BalloonError.mapping
    }
    let raw = mmap(nil, length, PROT_READ, MAP_SHARED, resource, off_t(base))
    guard raw != MAP_FAILED, raw != nil else { throw BalloonError.mapping }
    return (raw, length, offset)
  }

  func observe() throws -> (requested: UInt32, actual: UInt32)? {
    guard let mapping else { return nil }
    let address = UInt(bitPattern: mapping) + UInt(offset)
    for _ in 0..<8 {
      let first = VolatileMappedRegister<UInt32>(unsafeBitPattern: address).load()
      let actual = VolatileMappedRegister<UInt32>(unsafeBitPattern: address + 4).load()
      let second = VolatileMappedRegister<UInt32>(unsafeBitPattern: address).load()
      if first == second { return (UInt32(littleEndian: first), UInt32(littleEndian: actual)) }
    }
    throw BalloonError.changed
  }

  deinit {
    if let mapping { _ = munmap(mapping, length) }
  }
}
