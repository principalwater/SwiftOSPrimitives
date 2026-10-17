import BoundedMemory
import Foundation

/// One coordinator publication; byte counts are ownership/capacity observations, not RSS.
public struct NativeBalloonState: Sendable {
  public let epoch: UInt64
  public let ready: Bool
  public let targetBytes: UInt64
  public let actualBytes: UInt64
  public let ownedBytes: UInt64
  public let quarantined: Bool
  public let requestGeneration: UInt64
  public let appliedGeneration: UInt64
  public let zeroTargetObserved: Bool
  public let pendingRecyclingExtents: UInt64
  var requestApplied: Bool { requestGeneration == appliedGeneration }

  init(
    epoch: UInt64, ready: Bool, targetBytes: UInt64, actualBytes: UInt64, ownedBytes: UInt64,
    quarantined: Bool, requestGeneration: UInt64, appliedGeneration: UInt64,
    zeroTargetObserved: Bool, pendingRecyclingExtents: UInt64 = 0
  ) {
    self.epoch = epoch
    self.ready = ready
    self.targetBytes = targetBytes
    self.actualBytes = actualBytes
    self.ownedBytes = ownedBytes
    self.quarantined = quarantined
    self.requestGeneration = requestGeneration
    self.appliedGeneration = appliedGeneration
    self.zeroTargetObserved = zeroTargetObserved
    self.pendingRecyclingExtents = pendingRecyclingExtents
  }

  public var settled: Bool {
    requestApplied && targetBytes == actualBytes && targetBytes == ownedBytes
      && (targetBytes == 0 || pendingRecyclingExtents == 0)
      && (targetBytes != 0 || zeroTargetObserved)
  }
}

/// Persistent ownership of stock virtio-balloon 4 KiB PFNs, confined to the VM coordinator.
/// FrameLedger's contiguous generation tickets do not represent arbitrary driver PFN transfers.
struct BalloonPFNs {
  let boot: Range<UInt64>
  let dynamicBytes: UInt64
  private let bootPages: Int
  private var words: [UInt64]
  private var pendingRecycling: Set<Int> = []
  var pendingRecyclingCount: Int { pendingRecycling.count }
  private(set) var count: UInt32 = 0
  private(set) var dynamicCount: UInt32 = 0
  private(set) var fullyOwnedDynamicExtents: UInt32 = 0
  private(set) var peakFullyOwnedDynamicExtents: UInt32 = 0
  private(set) var epoch: UInt64 = 1

  init(boot: Range<UInt64>, dynamicBytes: UInt64) throws {
    guard !boot.isEmpty, boot.lowerBound % (2 << 20) == 0,
      boot.count <= 3 << 30, boot.upperBound <= MemoryDevice.base,
      boot.count % (2 << 20) == 0,
      dynamicBytes > 0, dynamicBytes <= 3 << 30, dynamicBytes % (2 << 20) == 0
    else { throw DeviceFailure.geometry }
    self.boot = boot
    self.dynamicBytes = dynamicBytes
    bootPages = boot.count / 4096
    words = .init(repeating: 0, count: (bootPages + Int(dynamicBytes / 4096)) / 64)
  }

  private func slot(_ pfn: UInt32) throws -> Int {
    let address = UInt64(pfn) << 12
    if boot.contains(address) { return Int((address - boot.lowerBound) / 4096) }
    guard address >= MemoryDevice.base, address - MemoryDevice.base < dynamicBytes else {
      throw DeviceFailure.request
    }
    return bootPages + Int((address - MemoryDevice.base) / 4096)
  }

  /// A device payload may not read or write pages currently transferred to the balloon.
  func overlapsOwned(address: UInt64, count: Int) throws -> Bool {
    guard count > 0, count <= 1 << 20, address <= UInt64.max - UInt64(count) else {
      throw DeviceFailure.request
    }
    let end = address + UInt64(count)
    guard address >= boot.lowerBound && end <= boot.upperBound
      || address >= MemoryDevice.base && end - MemoryDevice.base <= dynamicBytes
    else { throw DeviceFailure.request }
    let first = try slot(UInt32(address / 4096))
    let last = first + Int((address % 4096 + UInt64(count) - 1) / 4096)
    return (first...last).contains { words[$0 / 64] & (1 << ($0 % 64)) != 0 }
  }

  /// Checks the whole bounded packet before changing any ownership bit.
  mutating func transfer(_ pfns: [UInt32], inflate: Bool) throws -> [Int] {
    guard !pfns.isEmpty, pfns.count <= 256, Set(pfns).count == pfns.count else {
      throw DeviceFailure.request
    }
    let slots = try pfns.map { try slot($0) }
    for slot in slots {
      guard (words[slot / 64] & (1 << (slot % 64)) != 0) != inflate else {
        throw DeviceFailure.request
      }
    }
    var changed: Set<Int> = []
    for slot in slots {
      if !inflate, slot >= bootPages, ownsExtent((slot - bootPages) / 512) {
        fullyOwnedDynamicExtents -= 1
      }
      if inflate { words[slot / 64] |= 1 << (slot % 64) }
      else { words[slot / 64] &= ~(1 << (slot % 64)) }
      if slot >= bootPages { changed.insert((slot - bootPages) / 512) }
      if slot >= bootPages {
        if inflate { dynamicCount += 1 } else { dynamicCount -= 1 }
      }
    }
    if inflate { count += UInt32(slots.count) } else { count -= UInt32(slots.count) }
    guard inflate else {
      pendingRecycling.subtract(changed)
      return []
    }
    let eligible = changed.sorted().filter(ownsExtent)
    fullyOwnedDynamicExtents += UInt32(eligible.count)
    peakFullyOwnedDynamicExtents = max(peakFullyOwnedDynamicExtents, fullyOwnedDynamicExtents)
    pendingRecycling.formUnion(eligible)
    return eligible
  }

  /// Retain scattered completions across bounded coordinator turns, until deflate or reset.
  mutating func takeRecyclingBatch(limit: Int = 4) -> [Int] {
    precondition((0...4).contains(limit))
    let batch = Array(pendingRecycling.sorted().prefix(limit))
    pendingRecycling.subtract(batch)
    return batch
  }

  mutating func cancelRecycling() { pendingRecycling.removeAll(keepingCapacity: true) }

  func ownsExtent(_ index: Int) -> Bool {
    guard index >= 0, index < Int(dynamicBytes / UInt64(MemoryDevice.block)) else { return false }
    let first = (bootPages + index * 512) / 64
    return (first..<(first + 8)).allSatisfy { words[$0] == .max }
  }

  /// Complete aligned dynamic units owned now; boot is skipped (2 MiB aligned, so whole words).
  /// An upper bound before metadata pins, residency or backing, and no ledger state changes.
  func ownedCoverage() -> BalloonOwnershipCoverage {
    BalloonOwnershipCoverage(dynamicWords: words[(bootPages / 64)...])
  }

  /// Deflate never remaps: release every known owned PFN before ACK, even in a mixed packet.
  mutating func releaseOwned(_ pfns: [UInt32]) -> Bool {
    guard !pfns.isEmpty, pfns.count <= 256 else { return false }
    var valid = true
    for pfn in pfns {
      guard let slot = try? slot(pfn), words[slot / 64] & (1 << (slot % 64)) != 0 else {
        valid = false
        continue
      }
      if slot >= bootPages, ownsExtent((slot - bootPages) / 512) {
        fullyOwnedDynamicExtents -= 1
      }
      words[slot / 64] &= ~(1 << (slot % 64))
      if slot >= bootPages { pendingRecycling.remove((slot - bootPages) / 512) }
      count -= 1
      if slot >= bootPages { dynamicCount -= 1 }
    }
    return valid
  }

  mutating func reset() throws {
    guard epoch < .max else { throw DeviceFailure.request }
    epoch += 1
    for index in words.indices { words[index] = 0 }
    cancelRecycling()
    count = 0
    dynamicCount = 0
    fullyOwnedDynamicExtents = 0
  }
}

/// Default-off experiment: backing replacement needs persistent PFN ownership until deflate ACK.
/// Deflate clears ownership before ACK and never remaps; no async DMA/pointer escape is supported.
final class ClassicBalloonDevice {
  private var recyclingWindow = RecyclingWindow()
  private(set) var recyclingAttempts: UInt64 = 0
  private(set) var recyclingReplaced: UInt64 = 0
  private(set) var recyclingSkippedPinned: UInt64 = 0
  private(set) var recyclingSkippedEvidence: UInt64 = 0
  let transport = VirtioMMIO(
    identity: 5, features: (1 << 0) | (1 << 2), interrupt: 41,
    requiredFeatures: (1 << 32) | (1 << 0) | (1 << 2), queueCount: 2)
  private(set) var ledger: BalloonPFNs
  private(set) var target: UInt32 = 0
  private(set) var actual: UInt32 = 0
  private(set) var quarantined = false
  private var deadline: ContinuousClock.Instant?
  private var zeroReadGeneration: UInt32?
  var zeroTargetObserved: Bool {
    target == 0 && zeroReadGeneration == transport.generation
  }
  private var history = RecentHistory<[String: UInt64]>(capacity: 64)
  var observations: [[String: UInt64]] { history.elements }
  private(set) var accepted: UInt64 = 0
  private(set) var refused: UInt64 = 0
  private(set) var invalidActualWrites: UInt64 = 0
  private(set) var leaseExpirations: UInt64 = 0
  private var refusalHistory = RecentHistory<[String: Any]>(capacity: 16)
  var refusals: [[String: Any]] { refusalHistory.elements }
  private(set) var peakBootPFNs: UInt32 = 0
  private(set) var peakDynamicPFNs: UInt32 = 0
  private var coverageJournal = BalloonCoverageJournal()
  /// Final saved evidence only, read by the owning coordinator after the VM stops.
  var coverageEvidence: [String: Any] { coverageJournal.evidence(pulseActive: target != 0) }

  init(boot: Range<UInt64>, dynamicBytes: UInt64) throws {
    ledger = try BalloonPFNs(boot: boot, dynamicBytes: dynamicBytes)
  }

  private func setTarget(_ value: UInt32) throws {
    guard transport.generation < .max else { throw DeviceFailure.request }
    let previous = target
    target = value
    if value == 0 { ledger.cancelRecycling() }
    zeroReadGeneration = nil
    transport.generation += 1
    transport.interruptStatus |= 2
    // Diagnostics follow the safety mutation and cannot throw, renew a lease or edit ownership.
    coverageJournal.recordZeroTransition(from: previous, to: value, ledger: ledger)
  }

  /// One finite pulse; even a stalled caller cannot leave a nonzero target indefinitely.
  func request(bytes: UInt64, memory: MemoryDevice, now: ContinuousClock.Instant) throws {
    guard bytes % 4096 == 0, bytes <= ledger.dynamicBytes,
      memory.capacity == ledger.dynamicBytes,
      bytes == 0 || !memory.held && !memory.quarantined && bytes <= memory.plugged,
      bytes == 0 || !quarantined && actual == target && ledger.count == target
        && ledger.pendingRecyclingCount == 0
        && bytes > UInt64(target) * 4096
        && (target == 0 || deadline.map({ now < $0 }) == true),
      transport.status & 15 == 15
    else { throw DeviceFailure.request }
    let beginning = target == 0
    try setTarget(UInt32(bytes / 4096))
    if bytes == 0 { deadline = nil }
    else if beginning { deadline = now.advanced(by: .seconds(8)) }
  }

  func poll(now: ContinuousClock.Instant, quarantine: Bool) throws {
    if quarantine { quarantined = true }
    if quarantine || deadline.map({ now >= $0 }) == true {
      if let deadline, now >= deadline {
        guard leaseExpirations < .max else { throw DeviceFailure.request }
        leaseExpirations += 1
      }
      deadline = nil
      if target != 0 { try setTarget(0) }
    }
  }

  /// Ownership stays in the ledger after ACK; all vCPUs must still be parked before replacement.
  func recyclePending(
    memory: MemoryDevice, quiescence: (parked: Bool, epoch: Int, cpus: Int),
    acknowledgmentPending: Bool = false
  ) throws {
    guard quiescence.parked, quiescence.epoch >= 0, (1...4).contains(quiescence.cpus),
      memory.capacity == ledger.dynamicBytes, !memory.held else { throw DeviceFailure.request }
    guard target != 0, deadline.map({ ContinuousClock.now < $0 }) == true,
      !quarantined, !memory.quarantined else {
      ledger.cancelRecycling()
      return
    }
    let count = try recyclingWindow.admit(
      epoch: quiescence.epoch, pending: ledger.pendingRecyclingCount)
    guard count > 0 else { return }
    let batch = ledger.takeRecyclingBatch(limit: count)
    guard batch.allSatisfy(ledger.ownsExtent) else { throw DeviceFailure.request }
    for index in batch {
      guard target != 0, deadline.map({ ContinuousClock.now < $0 }) == true,
        !quarantined, !memory.quarantined else {
        ledger.cancelRecycling()
        return
      }
      guard recyclingAttempts < .max else { throw DeviceFailure.request }
      recyclingAttempts += 1
      let replaced = try memory.recycleOwned(
        [index], quiescence: quiescence, balloonEpoch: ledger.epoch,
        acknowledgmentPending: acknowledgmentPending)
      if replaced { recyclingReplaced += 1 }
      else if memory.extents[index].metadataPinned { recyclingSkippedPinned += 1 }
      else { recyclingSkippedEvidence += 1 }
    }
  }

  private func refuse(queue: UInt32?, reason: String) throws {
    quarantined = true
    deadline = nil
    if target != 0 { try setTarget(0) }
    if queue != nil {
      guard refused < .max else { throw DeviceFailure.request }
      refused += 1
    } else {
      guard invalidActualWrites < .max else { throw DeviceFailure.request }
      invalidActualWrites += 1
    }
    try refusalHistory.append([
      "epoch": ledger.epoch, "queue": queue.map { $0 as Any } ?? NSNull(),
      "reason": String(reason.prefix(160)), "ownedPFNs": ledger.count,
    ])
  }

  func access(
    _ offset: UInt64, width: Int, write: UInt32?, memory: MemoryDevice,
    metadata: (UInt64, Int) throws -> UnsafeMutableRawPointer,
    payload: (UInt64, Int) throws -> UnsafeMutableRawPointer,
    quiescence: (parked: Bool, epoch: Int, cpus: Int)
  ) throws -> UInt64 {
    guard quiescence.parked, quiescence.epoch >= 0, (1...4).contains(quiescence.cpus),
      memory.capacity == ledger.dynamicBytes, !memory.held,
      width == 4, offset % 4 == 0
    else { throw DeviceFailure.request }
    if offset >= 0x100 {
      guard offset == 0x100 || offset == 0x104 else { throw DeviceFailure.request }
      if let write {
        guard offset == 0x104 else { throw DeviceFailure.negotiation }
        guard UInt64(write) <= UInt64(ledger.boot.count) / 4096 + ledger.dynamicBytes / 4096
        else { try refuse(queue: nil, reason: "actual-out-of-range"); return 0 }
        actual = write // Guest telemetry never grants ownership.
      }
      // The stock driver's serialized resize worker reads zero after pending inflate ACKs.
      if write == nil, offset == 0x100, target == 0 {
        zeroReadGeneration = transport.generation
      }
      return UInt64(offset == 0x100 ? target : actual)
    }
    if let write {
      if try transport.write(offset, write, memory: metadata) {
        let inflate = write == 0
        if try transport.queues[Int(write)].drain(
          maximumBufferBytes: 1024, memory: metadata,
          process: { buffers in
            var pfns: [UInt32] = []
            let eligible: [Int]
            var invalidDeflate = false
            do {
              guard buffers.count <= 128 else { throw DeviceFailure.request }
              for buffer in buffers {
                guard !buffer.writable, buffer.size % 4 == 0,
                  buffer.size / 4 <= 256 - pfns.count
                else { throw DeviceFailure.request }
                let pointer = try payload(buffer.address, buffer.size)
                for offset in stride(from: 0, to: buffer.size, by: 4) {
                  pfns.append(pointer.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                    .littleEndian)
                }
              }
              if inflate {
                for pfn in pfns {
                  let address = UInt64(pfn) << 12
                  for buffer in buffers {
                    guard address + 4096 <= buffer.address
                      || buffer.address + UInt64(buffer.size) <= address
                    else { throw DeviceFailure.request }
                  }
                  if address >= MemoryDevice.base {
                    guard address - MemoryDevice.base < UInt64(memory.capacity) else {
                      throw DeviceFailure.request
                    }
                    let extent = memory.extents[Int((address - MemoryDevice.base)
                      / UInt64(MemoryDevice.block))]
                    guard extent.plugged, extent.mapped else { throw DeviceFailure.request }
                  }
                }
                eligible = try self.ledger.transfer(pfns, inflate: true)
              } else {
                eligible = []
                invalidDeflate = !self.ledger.releaseOwned(pfns)
              }
              self.peakDynamicPFNs = max(self.peakDynamicPFNs, self.ledger.dynamicCount)
              self.peakBootPFNs = max(
                self.peakBootPFNs, self.ledger.count - self.ledger.dynamicCount)
            } catch {
              // An undecodable deflate cannot ACK an unknown release; its owner must stop the VM.
              try self.refuse(queue: write, reason: String(describing: error))
              if !inflate { throw error }
              return 0
            }
            if invalidDeflate {
              try self.refuse(queue: write, reason: "mixed-deflate-pfns")
              return 0
            }
            let before = memory.recycledResidentBytes
            let beforeBacking = memory.recycledBackingBytes
            if inflate, self.target != 0, self.ledger.count > self.target {
              try self.refuse(queue: write, reason: "inflate-exceeds-target")
            }
            let authorized = self.target != 0
              && self.deadline.map({ ContinuousClock.now < $0 }) == true
              && !self.quarantined && !memory.quarantined
            if inflate {
              if authorized {
                // A failure after native retirement must escape and stop the VM, never be ACKed.
                // A scattered packet cannot turn one ACK into hundreds of parked native calls.
                try self.recyclePending(
                  memory: memory, quiescence: quiescence, acknowledgmentPending: true)
              } else {
                self.ledger.cancelRecycling()
              }
            } else if self.target != 0 {
              // Migration/OOM unsolicited deflate revokes the pulse; never reinflate automatically.
              self.quarantined = true
              self.deadline = nil
              try self.setTarget(0)
            }
            guard self.accepted < .max else { throw DeviceFailure.request }
            self.accepted += 1
            try self.history.append([
              "sequence": self.accepted, "epoch": self.ledger.epoch,
              "inflate": inflate ? 1 : 0, "transferredPFNs": UInt64(pfns.count),
              "ownedPFNs": UInt64(self.ledger.count), "targetPFNs": UInt64(self.target),
              "ownedDynamicPFNs": UInt64(self.ledger.dynamicCount),
              "actualPFNs": UInt64(self.actual), "eligibleDynamicExtents": UInt64(eligible.count),
              "pendingRecyclingExtents": UInt64(self.ledger.pendingRecyclingCount),
              "recycleAuthorized": authorized ? 1 : 0,
              "replacedExtents": (memory.recycledBackingBytes - beforeBacking)
                / UInt64(MemoryDevice.block),
              "residentBytesRecycled": memory.recycledResidentBytes - before,
            ])
            return 0
          })
        { transport.interruptStatus |= 1 }
      }
      if offset == 0x70, write == 0 {
        try ledger.reset()
        target = 0
        actual = 0
        zeroReadGeneration = nil
        deadline = nil
      }
      return 0
    }
    return UInt64(transport.read(offset))
  }
}
