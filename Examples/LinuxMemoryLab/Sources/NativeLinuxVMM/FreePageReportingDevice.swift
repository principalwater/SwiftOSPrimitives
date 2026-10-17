import BoundedMemory
import Foundation

/// REPORTING owns free pages until used-ring ACK; FREE_PAGE_HINT never grants that ownership.
final class FreePageReportingDevice {
  // MMIO compacts absent optional queues: reporting follows inflate/deflate without stats/hint.
  private static let reportingQueue: UInt32 = 2
  let transport = VirtioMMIO(
    identity: 5, features: (1 << 4) | (1 << 5), interrupt: 41,
    requiredFeatures: (1 << 32) | (1 << 5), queueCount: 3)
  private(set) var poison: UInt32 = 0
  private(set) var reports: UInt64 = 0
  private(set) var reportedBytes: UInt64 = 0
  private let began = ContinuousClock.now
  private var history = RecentHistory<[String: UInt64]>(capacity: 64)
  var observations: [[String: UInt64]] { history.elements }

  private func now() throws -> UInt64 {
    let duration = began.duration(to: .now).components
    guard duration.seconds >= 0, duration.seconds <= Int64.max / 1_000_000_000 else {
      throw DeviceFailure.request
    }
    return UInt64(duration.seconds) * 1_000_000_000
      + UInt64(duration.attoseconds / 1_000_000_000)
  }

  /// Validate the complete chain before selecting whole dynamic extents; never combine subpages.
  static func indices(
    _ buffers: [GuestBuffer], boot: Range<UInt64>, dynamicBytes: UInt64
  ) throws -> [Int] {
    guard !buffers.isEmpty, buffers.count <= 128 else { throw DeviceFailure.request }
    var ranges: [Range<UInt64>] = []
    for buffer in buffers {
      guard buffer.writable, buffer.size > 0, buffer.size <= 64 << 20,
        buffer.address % 4096 == 0, buffer.size % 4096 == 0,
        buffer.address <= UInt64.max - UInt64(buffer.size)
      else { throw DeviceFailure.request }
      let end = buffer.address + UInt64(buffer.size)
      let inBoot = buffer.address >= boot.lowerBound && end <= boot.upperBound
      let inDynamic = buffer.address >= MemoryDevice.base
        && end - MemoryDevice.base <= dynamicBytes
      guard inBoot || inDynamic else { throw DeviceFailure.request }
      ranges.append(buffer.address..<end)
    }
    ranges.sort { $0.lowerBound < $1.lowerBound }
    for index in 1..<ranges.count {
      guard ranges[index - 1].upperBound <= ranges[index].lowerBound else {
        throw DeviceFailure.descriptor("overlapping-reports")
      }
    }
    let block = UInt64(MemoryDevice.block)
    var indices: [Int] = []
    for range in ranges where range.lowerBound >= MemoryDevice.base {
      let first = (range.lowerBound - MemoryDevice.base + block - 1) / block
      let end = (range.upperBound - MemoryDevice.base) / block
      if first < end { indices += (first..<end).map { Int($0) } }
    }
    return indices
  }

  func access(
    _ offset: UInt64, width: Int, write: UInt32?,
    boot: Range<UInt64>, memory: MemoryDevice,
    metadata: (UInt64, Int) throws -> UnsafeMutableRawPointer,
    quiescence: (parked: Bool, epoch: Int, cpus: Int)
  ) throws -> UInt64 {
    guard quiescence.parked, width == 4, offset % 4 == 0 else {
      throw DeviceFailure.request
    }
    if offset >= 0x100 {
      guard offset <= 0x10c else { throw DeviceFailure.request }
      if let write {
        if offset == 0x104, write == 0 { return 0 }
        guard offset == 0x10c, transport.driverFeatures & (1 << 4) != 0 else {
          throw DeviceFailure.negotiation
        }
        poison = write
      }
      return offset == 0x10c ? UInt64(poison) : 0
    }
    if let write {
      if offset == 0x50, write != Self.reportingQueue { throw DeviceFailure.negotiation }
      if try transport.write(offset, write, memory: metadata) {
        if try transport.queues[Int(Self.reportingQueue)].drain(
          maximumBufferBytes: 64 << 20, memory: metadata,
          process: { buffers in
            let received = try self.now()
            let residentBefore = memory.recycledResidentBytes
            let indices = try Self.indices(
              buffers, boot: boot, dynamicBytes: UInt64(memory.capacity))
            let bytes = buffers.reduce(UInt64(0)) { $0 + UInt64($1.size) }
            guard self.reports < UInt64.max, self.reportedBytes <= UInt64.max - bytes else {
              throw DeviceFailure.request
            }
            // Nonzero poisoning is retained unchanged; replacing it with lazy zeroes is unsafe.
            if self.poison == 0 {
              try memory.recycleOwned(indices, quiescence: quiescence)
            }
            self.reports += 1
            self.reportedBytes += bytes
            try self.history.append([
              "sequence": self.reports,
              "receivedAtNanoseconds": received, "completedAtNanoseconds": self.now(),
              "bufferCount": UInt64(buffers.count), "reportedBytes": bytes,
              "minimumBufferBytes": UInt64(buffers.lazy.map(\.size).min() ?? 0),
              "maximumBufferBytes": UInt64(buffers.lazy.map(\.size).max() ?? 0),
              "wholeDynamicExtents": UInt64(indices.count),
              "residentBytesRecycled": memory.recycledResidentBytes - residentBefore,
            ])
            return 0
          })
        {
          transport.interruptStatus |= 1
        }
      }
      if offset == 0x70, write == 0 { poison = 0 }
      return 0
    }
    return UInt64(transport.read(offset))
  }
}
