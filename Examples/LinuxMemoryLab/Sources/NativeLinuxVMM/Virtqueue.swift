import Foundation

// Only used while the sole vCPU is stopped; no asynchronous DMA or shared rings.
enum DeviceFailure: Error {
  case geometry, negotiation, request
  case native(Int32)
  case descriptor(String)
  case observation(String)
}

struct GuestBuffer {
  let address: UInt64
  let size: Int
  let writable: Bool
}

struct SplitQueue {
  var size: UInt32 = 0
  var descriptors: UInt64 = 0
  var available: UInt64 = 0
  var used: UInt64 = 0
  var ready = false
  var consumed: UInt16 = 0
  var completed: UInt16 = 0

  func validate(_ memory: (UInt64, Int) throws -> UnsafeMutableRawPointer) throws {
    guard size >= 2, size <= 128, size.nonzeroBitCount == 1,
      descriptors % 16 == 0, available % 2 == 0, used % 4 == 0
    else { throw DeviceFailure.geometry }
    let ranges = [
      (descriptors, Int(size) * 16), (available, 6 + Int(size) * 2),
      (used, 6 + Int(size) * 8),
    ]
    for (address, bytes) in ranges { _ = try memory(address, bytes) }
    for first in 0..<ranges.count {
      for second in (first + 1)..<ranges.count {
        let a = ranges[first]
        let b = ranges[second]
        guard a.0 + UInt64(a.1) <= b.0 || b.0 + UInt64(b.1) <= a.0 else {
          throw DeviceFailure.geometry
        }
      }
    }
  }

  mutating func drain(
    memory: (UInt64, Int) throws -> UnsafeMutableRawPointer,
    process: ([GuestBuffer]) throws -> UInt32?
  ) throws -> Bool {
    guard ready else { throw DeviceFailure.negotiation }
    try validate(memory)
    let avail = try memory(available, 6 + Int(size) * 2)
    let published = avail.loadUnaligned(fromByteOffset: 2, as: UInt16.self).littleEndian
    guard UInt32(published &- consumed) <= size else {
      throw DeviceFailure.descriptor("available-overrun")
    }
    let table = try memory(descriptors, Int(size) * 16)
    let usedRing = try memory(used, 6 + Int(size) * 8)
    var changed = false
    while consumed != published {
      let head = avail.loadUnaligned(
        fromByteOffset: 4 + Int(consumed % UInt16(size)) * 2,
        as: UInt16.self
      ).littleEndian
      var index = head
      var visited = Set<UInt16>()
      var buffers: [GuestBuffer] = []
      while true {
        guard UInt32(index) < size, visited.insert(index).inserted else {
          throw DeviceFailure.descriptor("index-or-cycle")
        }
        let descriptor = table.advanced(by: Int(index) * 16)
        let address = descriptor.loadUnaligned(as: UInt64.self).littleEndian
        let length = descriptor.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian
        let flags = descriptor.loadUnaligned(fromByteOffset: 12, as: UInt16.self).littleEndian
        let next = descriptor.loadUnaligned(fromByteOffset: 14, as: UInt16.self).littleEndian
        guard flags & ~3 == 0, length > 0, length <= 1 << 20,
          address <= UInt64.max - UInt64(length)
        else {
          throw DeviceFailure.descriptor("flags=\(flags) length=\(length) address=\(address)")
        }
        // A device may not overwrite its own descriptors or completion metadata.
        for (start, bytes) in [
          (descriptors, Int(size) * 16),
          (available, 6 + Int(size) * 2), (used, 6 + Int(size) * 8),
        ] {
          guard address + UInt64(length) <= start || start + UInt64(bytes) <= address else {
            throw DeviceFailure.descriptor("metadata-alias")
          }
        }
        buffers.append(GuestBuffer(address: address, size: Int(length), writable: flags & 2 != 0))
        if flags & 1 == 0 { break }
        index = next
      }
      guard buffers.count <= 128 else { throw DeviceFailure.descriptor("chain-limit") }
      guard let written = try process(buffers) else { break }
      let offset = 4 + Int(completed % UInt16(size)) * 8
      usedRing.storeBytes(of: UInt32(head).littleEndian, toByteOffset: offset, as: UInt32.self)
      usedRing.storeBytes(of: written.littleEndian, toByteOffset: offset + 4, as: UInt32.self)
      completed &+= 1
      // No other guest CPU or device thread exists; native re-entry follows these stores.
      usedRing.storeBytes(of: completed.littleEndian, toByteOffset: 2, as: UInt16.self)
      consumed &+= 1
      changed = true
    }
    return changed
  }
}

final class VirtioMMIO {
  let identity: UInt32
  let features: UInt64
  let interrupt: UInt32
  let requiredFeatures: UInt64
  var queues: [SplitQueue]
  var queue: SplitQueue {
    get { queues[Int(selection)] }
    set { queues[Int(selection)] = newValue }
  }
  var deviceFeaturePage: UInt32 = 0
  var driverFeaturePage: UInt32 = 0
  var driverFeatures: UInt64 = 0
  var selection: UInt32 = 0
  var status: UInt32 = 0
  var interruptStatus: UInt32 = 0
  var generation: UInt32 = 0

  init(
    identity: UInt32, features: UInt64, interrupt: UInt32,
    requiredFeatures: UInt64 = 1 << 32, queueCount: Int = 1
  ) {
    queues = (0..<queueCount).map { _ in SplitQueue() }
    self.identity = identity
    self.features = features | (1 << 32)
    self.interrupt = interrupt
    self.requiredFeatures = requiredFeatures
  }

  func read(_ offset: UInt64) -> UInt32 {
    switch offset {
    case 0: return 0x7472_6976
    case 4: return 2
    case 8: return identity
    case 12: return 0x5357_504d
    case 0x10:
      return deviceFeaturePage < 2
        ? UInt32(
          truncatingIfNeeded:
            features >> (deviceFeaturePage * 32)) : 0
    case 0x34: return Int(selection) < queues.count ? 128 : 0
    case 0x44: return Int(selection) < queues.count && queue.ready ? 1 : 0
    case 0x60: return interruptStatus
    case 0x70: return status
    case 0xfc: return generation
    default: return 0
    }
  }

  // Notify/config/IRQ handling is synchronous in the owning LinuxMachine.
  func write(
    _ offset: UInt64, _ value: UInt32,
    memory: (UInt64, Int) throws -> UnsafeMutableRawPointer
  ) throws -> Bool {
    func half(_ old: UInt64, high: Bool) -> UInt64 {
      high
        ? (old & 0xffff_ffff) | (UInt64(value) << 32)
        : (old & 0xffff_ffff_0000_0000) | UInt64(value)
    }
    switch offset {
    case 0x14: deviceFeaturePage = value
    case 0x24: driverFeaturePage = value
    case 0x20:
      guard driverFeaturePage < 2, status & 8 == 0 else { throw DeviceFailure.negotiation }
      driverFeatures = half(driverFeatures, high: driverFeaturePage == 1)
    case 0x30: selection = value
    case 0x64: interruptStatus &= ~value
    case 0x70:
      if value == 0 {
        queues = queues.map { _ in SplitQueue() }
        driverFeatures = 0
        deviceFeaturePage = 0
        driverFeaturePage = 0
        selection = 0
        interruptStatus = 0
        status = 0
      } else {
        guard value & status == status else { throw DeviceFailure.negotiation }
        status = value
        if value & 8 != 0,
          driverFeatures & ~features != 0 || driverFeatures & requiredFeatures != requiredFeatures
        {
          status &= ~8
        }
      }
    case 0x38, 0x44, 0x80, 0x84, 0x90, 0x94, 0xa0, 0xa4:
      guard Int(selection) < queues.count, status & 8 != 0 else { throw DeviceFailure.negotiation }
      if offset == 0x44 {
        guard value == 1, !queue.ready else { throw DeviceFailure.negotiation }
        try queue.validate(memory)
        queue.ready = true
      } else {
        guard !queue.ready else { throw DeviceFailure.negotiation }
        switch offset {
        case 0x38: queue.size = value
        case 0x80, 0x84: queue.descriptors = half(queue.descriptors, high: offset == 0x84)
        case 0x90, 0x94: queue.available = half(queue.available, high: offset == 0x94)
        case 0xa0, 0xa4: queue.used = half(queue.used, high: offset == 0xa4)
        default: break
        }
      }
    case 0x50:
      guard Int(value) < queues.count, status & 12 == 12, queues[Int(value)].ready else {
        throw DeviceFailure.negotiation
      }
      return true
    default: break
    }
    return false
  }
}
