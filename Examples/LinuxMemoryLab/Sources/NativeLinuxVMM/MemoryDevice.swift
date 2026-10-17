import BoundedMemory
import Darwin
import Foundation
import Hypervisor
import PageMemory

// Exclusively owned dynamic RAM region, never a borrowed VZ allocation. In this private candidate
// each 2 MiB extent is one named purgable Mach object owned by MachNamedBacking.
final class MemoryDevice {
  static let base: UInt64 = 0x1_0000_0000
  static let block = 2 << 20
  let capacity: Int
  final class Extent {
    var backing: MachNamedBacking?
    /// Confined host address of the owned mapping; nil after an unplug detached it.
    var pointer: UnsafeMutableRawPointer? { backing?.pointer }
    var mapped = false
    var plugged = false
    var freshAllocation = false
    var initializedByHost = false
    var metadataPinned = false
  }
  let thread = pthread_self()
  let held: Bool
  let aliasControl: Bool
  let coldProvisioning: Bool
  var aliasAddress: UInt64?
  var aliasReleased = false
  private var refusalHistory = RecentHistory<[String: Any]>(capacity: 128)
  var refusals: [[String: Any]] { refusalHistory.elements }
  var refusalsTotal: UInt64 { refusalHistory.totalCount }
  let transport = VirtioMMIO(
    identity: 24, features: 1 << 1, interrupt: 35,
    requiredFeatures: (1 << 32) | 2)
  var extents: [Extent]
  var requested: UInt64
  private var observationHistory = RecentHistory<[String: Any]>(capacity: 1024)
  var observations: [[String: Any]] { observationHistory.elements }
  var observationsTotal: UInt64 { observationHistory.totalCount }
  private(set) var cumulativeBackingRetiredBytes: UInt64 = 0
  private var recyclingHistory = RecentHistory<[String: Any]>(capacity: 1024)
  var recyclingObservations: [[String: Any]] { recyclingHistory.elements }
  var recyclingObservationsTotal: UInt64 { recyclingHistory.totalCount }
  private(set) var recycledBackingBytes: UInt64 = 0
  private(set) var recycledResidentBytes: UInt64 = 0
  private(set) var recycledColdResidentBytes: UInt64 = 0
  private(set) var quarantined = false
  private(set) var quarantineRecord: [String: UInt64] = [:]
  // Only committed provide/retire/close mutate this logical count; avoid an ARC walk per VM exit.
  private(set) var plugged: UInt64 = 0
  // Uncertain ownership, failed restoration or destruction cannot authorize further reuse;
  // the VM owner must retain its admission lease and retire the process.
  private(set) var nativeFailure: String?

  init(
    held: Bool, aliasControl: Bool = false, geometry: NativeMemoryGeometry = .qualification,
    coldProvisioning: Bool = false
  ) {
    capacity = Int(geometry.dynamicBytes)
    requested = geometry.dynamicBytes
    extents = (0..<(Int(geometry.dynamicBytes) / Self.block)).map { _ in Extent() }
    self.held = held
    self.aliasControl = aliasControl
    self.coldProvisioning = coldProvisioning
  }

  private func native(_ result: Int32) throws {
    guard result == 0 else { throw DeviceFailure.native(result) }
  }
  private func confined() throws {
    guard pthread_equal(thread, pthread_self()) != 0 else { throw DeviceFailure.request }
  }
  /// Pins are conservative until VM destruction; reset or forged PFNs cannot revoke host pointers.
  func pinMetadata(_ index: Int, quiescence: (parked: Bool, epoch: Int, cpus: Int)) throws {
    try confined()
    guard quiescence.parked, quiescence.epoch >= 0, (1...4).contains(quiescence.cpus),
      extents.indices.contains(index), extents[index].plugged, extents[index].mapped,
      extents[index].pointer != nil
    else { throw DeviceFailure.request }
    extents[index].metadataPinned = true
  }
  func quarantine(quiescence: (parked: Bool, epoch: Int, cpus: Int)) throws {
    try confined()
    guard quiescence.parked, quiescence.epoch >= 0, (1...4).contains(quiescence.cpus) else {
      throw DeviceFailure.request
    }
    guard !quarantined else { return }
    quarantined = true
    requested = plugged
    quarantineRecord = [
      "pluggedBytes": plugged, "requestedBytes": requested,
      "epoch": UInt64(quiescence.epoch), "vcpuCount": UInt64(quiescence.cpus),
      "allVCPUsParked": 1,
    ]
  }
  func config() -> Data {
    let words: [UInt64] = [
      UInt64(Self.block), 0, Self.base, UInt64(capacity),
      UInt64(capacity), plugged, requested,
    ]
    return words.reduce(into: Data()) { bytes, word in
      var value = word.littleEndian
      withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) }
    }
  }
  func request(
    _ data: Data, quiescence: (parked: Bool, epoch: Int, cpus: Int)
  ) throws -> Data {
    try confined()
    guard data.count == 24, quiescence.parked, (1...4).contains(quiescence.cpus) else {
      throw DeviceFailure.request
    }
    func load<T: FixedWidthInteger>(_ offset: Int, _ type: T.Type) -> T {
      data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self).littleEndian }
    }
    let kind = load(0, UInt16.self)
    let address = load(8, UInt64.self)
    let blocks = Int(load(16, UInt16.self))
    var response: UInt16 = 0
    var state: UInt16 = 0
    if kind == 2 {
      if quarantined { return Self.reply(type: 2, state: 0) }
      // Startup/reset only: the standard driver guarantees no active users here.
      if try !retire(
        Array(extents.indices.filter { extents[$0].plugged || extents[$0].mapped }),
        quiescence: quiescence)
      {
        response = 2
      }
    } else if kind <= 3 {
      guard blocks > 0, address >= Self.base,
        (address - Self.base) % UInt64(Self.block) == 0,
        address - Self.base < UInt64(capacity),
        UInt64(blocks) <= (UInt64(capacity) - (address - Self.base)) / UInt64(Self.block)
      else { return Self.reply(type: 3, state: 0) }
      let first = Int((address - Self.base) / UInt64(Self.block))
      let indices = first..<(first + blocks)
      if quarantined, kind != 3 { return Self.reply(type: 2, state: 0) }
      switch kind {
      case 0:
        if indices.contains(where: { extents[$0].plugged })
          || UInt64(blocks * Self.block) > requested - min(requested, plugged)
        {
          response = 1
        } else {
          for index in indices { try provide(index) }
        }
      case 1:
        if indices.contains(where: { !extents[$0].plugged }) {
          response = 3
        } else {
          if try !retire(Array(indices), quiescence: quiescence) { response = 2 }
        }
      case 3:
        let count = indices.filter { extents[$0].plugged }.count
        state = count == blocks ? 0 : count == 0 ? 1 : 2
      default: throw DeviceFailure.request
      }
    } else {
      response = 3
    }
    return Self.reply(type: response, state: state)
  }
  static func reply(type: UInt16, state: UInt16) -> Data {
    var bytes = Data(count: 10)
    bytes[0] = UInt8(truncatingIfNeeded: type)
    bytes[1] = UInt8(truncatingIfNeeded: type >> 8)
    bytes[8] = UInt8(truncatingIfNeeded: state)
    bytes[9] = UInt8(truncatingIfNeeded: state >> 8)
    return bytes
  }
  private func provide(_ index: Int) throws {
    let extent = extents[index]
    guard nativeFailure == nil, !extent.plugged, !extent.mapped,
      plugged <= UInt64(capacity - Self.block) else { throw DeviceFailure.request }
    extent.freshAllocation = extent.pointer == nil
    if extent.freshAllocation { try attach(extent) }
    guard let pointer = extent.pointer else { throw DeviceFailure.request }
    // A cold object supplies zeroes lazily; reused held pages must be cleared.
    if !coldProvisioning || !extent.freshAllocation {
      memset(pointer, 0, Self.block)
      extent.initializedByHost = true
    } else {
      extent.initializedByHost = false
    }
    // Ordinary Linux RAM: guest stage1 enforces code permissions; host mapping stays RW/NX.
    try mapStage2(index, pointer)
    extent.mapped = true
    extent.plugged = true
    plugged += UInt64(Self.block)
    if aliasControl, !aliasReleased, index == 32, aliasAddress == nil {
      var target: UInt64 = 0
      var current: vm_prot_t = 0
      var maximum: vm_prot_t = 0
      try native(
        mach_vm_remap(
          mach_task_self_, &target, UInt64(Self.block), 0,
          VM_FLAGS_ANYWHERE, mach_task_self_, UInt64(UInt(bitPattern: pointer)), 0,
          &current, &maximum, VM_INHERIT_NONE))
      aliasAddress = target
    }
  }
  /// A first plug creates the named object; a replug after unplug maps the retained entry again.
  private func attach(_ extent: Extent) throws {
    if let backing = extent.backing { try backing.attachMapping() }
    else { extent.backing = try MachNamedBacking.create() }
  }
  private func mapStage2(_ index: Int, _ pointer: UnsafeMutableRawPointer) throws {
    try native(
      hv_vm_map(
        pointer, Self.base + UInt64(index * Self.block), Self.block,
        UInt64(HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC)))
  }
  func releaseAlias() throws {
    try confined()
    if let address = aliasAddress {
      try native(mach_vm_deallocate(mach_task_self_, address, UInt64(Self.block)))
      aliasAddress = nil
    }
    aliasReleased = true
  }
  private func restore(_ indices: [Int]) throws {
    for index in indices {
      let extent = extents[index]
      guard let pointer = extent.pointer, extent.plugged, !extent.mapped else {
        throw DeviceFailure.request
      }
      try mapStage2(index, pointer)
      extent.mapped = true
    }
  }
  private struct Transaction {
    let quiescence: (parked: Bool, epoch: Int, cpus: Int)
    let replacing: Bool
    let balloonEpoch: UInt64?
    let acknowledgmentPending: Bool
  }
  private struct Evidence {
    let inspection: MachNamedBacking.Inspection
    let discard: MachNamedBacking.Discard?
    let replacement: MachNamedBacking.Counts?
    let replacementBytes: UInt64?
    let residentBefore: UInt64
    let previouslyInitializedByHost: Bool
    let ownerRangeDeallocated: Bool
    let footprint: (before: ProcessMemorySnapshot, after: ProcessMemorySnapshot)
  }
  private func unmapStage2(_ indices: [Int]) throws -> [Int] {
    var unmapped: [Int] = []
    for index in indices {
      let extent = extents[index]
      guard extent.plugged else { throw DeviceFailure.request }
      if extent.mapped {
        try native(hv_vm_unmap(Self.base + UInt64(index * Self.block), Self.block))
        extent.mapped = false
        unmapped.append(index)
      }
    }
    return unmapped
  }
  private func preflight(_ index: Int) throws -> MachNamedBacking.Inspection {
    guard let backing = extents[index].backing else { throw DeviceFailure.request }
    return try backing.inspect()
  }
  private func recordRefusal(_ reason: String, unmapped: Int, replacing: Bool) throws {
    try refusalHistory.append([
      "reason": reason, "unmappedThenRestored": unmapped,
      "ownedBytesDeallocated": 0, "objectBytesDiscarded": 0,
      "reply": replacing ? "REPORT_SKIPPED" : "BUSY",
    ])
  }
  private func retire(
    _ indices: [Int], quiescence: (parked: Bool, epoch: Int, cpus: Int), replacing: Bool = false,
    balloonEpoch: UInt64? = nil, acknowledgmentPending: Bool = true
  ) throws -> Bool {
    let remaining = replacing ? recyclingHistory.remainingCounterValues
      : observationHistory.remainingCounterValues
    let cumulative = replacing ? recycledBackingBytes : cumulativeBackingRetiredBytes
    guard nativeFailure == nil, !replacing || !held, remaining >= UInt64(indices.count),
      replacing || plugged >= UInt64(indices.count) * UInt64(Self.block),
      UInt64.max - cumulative >= UInt64(indices.count) * UInt64(Self.block),
      indices.allSatisfy({ extents[$0].plugged && extents[$0].mapped && extents[$0].pointer != nil }
      )
    else { throw DeviceFailure.request }
    if indices.contains(where: { extents[$0].metadataPinned }) {
      try recordRefusal("metadata-pinned", unmapped: 0, replacing: replacing)
      return false
    }
    let transaction = Transaction(
      quiescence: quiescence, replacing: replacing, balloonEpoch: balloonEpoch,
      acknowledgmentPending: acknowledgmentPending)
    var unmapped: [Int] = []
    var discarded = 0
    do {
      unmapped = try unmapStage2(indices)
      let planned = try indices.map(preflight)
      for (index, plan) in zip(indices, planned) {
        if try retireOne(index, plan, transaction) { discarded += 1 }
      }
    } catch let refusal as MachNamedBacking.Refusal where discarded == 0 {
      // The first point of destruction rechecked ownership and refused: nothing was destroyed.
      do {
        try restore(unmapped)
        try recordRefusal(refusal.detail, unmapped: unmapped.count, replacing: replacing)
      } catch {
        nativeFailure = String(describing: error)
        throw error
      }
      return false
    } catch {
      // Uncertain ownership or native failures cannot authorize restoration or process reuse.
      nativeFailure = String(describing: error)
      throw error
    }
    return true
  }
  /// Returns true when the object's contents were discarded. Each extent's own discard rechecks
  /// ownership immediately before destroying, so an alias that appeared after the bulk plan wins.
  private func retireOne(
    _ index: Int, _ planned: MachNamedBacking.Inspection, _ transaction: Transaction
  ) throws -> Bool {
    let extent = extents[index]
    // Destruction needs the stage-2 mapping to be gone already, not merely requested to go.
    guard extent.plugged, !extent.mapped, let backing = extent.backing else {
      throw DeviceFailure.request
    }
    let before = try ProcessMemorySnapshot.capture()
    let previouslyInitializedByHost = extent.initializedByHost
    var discard: MachNamedBacking.Discard?
    if !held { discard = try backing.discard() }
    let inspection = discard?.before ?? planned
    let residentBefore = try inspection.counts.residentBytes()
    var replacement: MachNamedBacking.Counts?
    var replacementBytes: UInt64?
    var ownerRangeDeallocated = false
    if transaction.replacing {
      let counts = try remapCold(index)
      replacement = counts
      replacementBytes = try counts.residentBytes()
    } else {
      if !held {
        try backing.detachMapping()
        ownerRangeDeallocated = true
      }
      extent.plugged = false
      plugged -= UInt64(Self.block)
    }
    let after = try ProcessMemorySnapshot.capture()
    if transaction.replacing {
      recycledBackingBytes += UInt64(Self.block)
      recycledResidentBytes += residentBefore
      if !previouslyInitializedByHost { recycledColdResidentBytes += residentBefore }
    } else if !held {
      cumulativeBackingRetiredBytes += UInt64(Self.block)
    }
    let record = observation(
      index,
      Evidence(
        inspection: inspection, discard: discard, replacement: replacement,
        replacementBytes: replacementBytes, residentBefore: residentBefore,
        previouslyInitializedByHost: previouslyInitializedByHost,
        ownerRangeDeallocated: ownerRangeDeallocated, footprint: (before, after)),
      transaction)
    if transaction.replacing { try recyclingHistory.append(record) }
    else { try observationHistory.append(record) }
    return discard != nil
  }
  /// Same owned address and same GPA, with no virtual-range hole. Host writes are forbidden so
  /// the discarded object must still be cold when the guest is acknowledged or resumed.
  private func remapCold(_ index: Int) throws -> MachNamedBacking.Counts {
    let extent = extents[index]
    guard let pointer = extent.pointer, let backing = extent.backing else {
      throw DeviceFailure.request
    }
    try mapStage2(index, pointer)
    extent.mapped = true
    extent.freshAllocation = true
    extent.initializedByHost = false
    let counts = try backing.counts()
    guard counts.resident == 0, counts.swapped == 0 else {
      throw DeviceFailure.observation("replacement-not-cold")
    }
    return counts
  }
  private static let discardMechanism =
    "mach_memory_entry_purgable_control EMPTY then NONVOLATILE on the whole named object"
  private static func value<T>(_ optional: T?) -> Any {
    optional.map { $0 as Any } ?? NSNull()
  }
  private func observation(
    _ index: Int, _ evidence: Evidence, _ transaction: Transaction
  ) -> [String: Any] {
    let extent = extents[index]
    let inspection = evidence.inspection
    let quiescence = transaction.quiescence
    let replacing = transaction.replacing
    var record: [String: Any] = [
      "allVCPUsParked": quiescence.parked, "quiescentEpoch": quiescence.epoch,
      "vcpuCount": quiescence.cpus,
      "index": index, "held": held,
      "nativeEntryBytes": inspection.size, "nativeObjectOffset": inspection.offset,
      "freshAllocation": extent.freshAllocation,
      "hostInitializedBytes": evidence.previouslyInitializedByHost ? Self.block : 0,
      "residentObservationIncludesHostZeroing": evidence.previouslyInitializedByHost,
      "replacementHostInitializedBytes": replacing ? 0 : NSNull(),
      // Removing the owner's virtual range and discarding object contents are distinct facts.
      "oldVirtualRangeAbsent": evidence.ownerRangeDeallocated,
      "ownerVirtualBytesDeallocated": evidence.ownerRangeDeallocated ? Self.block : 0,
      "sameGPAMappedBeforeAcknowledgement":
        replacing && extent.mapped && transaction.acknowledgmentPending,
      "sameGPAMappedBeforeResume": replacing && extent.mapped,
      "balloonOwnershipEpoch": Self.value(transaction.balloonEpoch),
      "replacementResidentBytes": Self.value(evidence.replacementBytes),
      "objectID": inspection.objectID,
      "residentPagesBefore": inspection.counts.resident,
      "pagedOutPagesBefore": inspection.counts.swapped,
      "residentBytesObservedBefore": evidence.residentBefore,
      "referenceCount": inspection.references,
      "footprintBefore": Self.value(evidence.footprint.before.physicalFootprintBytes),
      "footprintAfter": Self.value(evidence.footprint.after.physicalFootprintBytes),
      "physicalReleasedBytes": NSNull(),
    ]
    let discarded = evidence.discard != nil
    record["backingKind"] = "mach-named-purgable-whole-object"
    record["objectContentsDiscarded"] = discarded
    record["discardMechanism"] = discarded ? Self.discardMechanism : "none-held-control"
    record["directCountSource"] = "mach_memory_entry_get_page_counts"
    record["directCountPageBytes"] = MachNamedBacking.pageBytes
    record["directResidentPagesBefore"] = inspection.counts.resident
    record["directDirtyPagesBefore"] = inspection.counts.dirty
    record["directSwappedPagesBefore"] = inspection.counts.swapped
    record["regionResidentPagesBefore"] = inspection.regionResidentPages
    record["directResidentPagesAfterDiscard"] = Self.value(evidence.discard?.after.resident)
    record["directDirtyPagesAfterDiscard"] = Self.value(evidence.discard?.after.dirty)
    record["directSwappedPagesAfterDiscard"] = Self.value(evidence.discard?.after.swapped)
    record["directResidentPagesAfterRemap"] = Self.value(evidence.replacement?.resident)
    record["directSwappedPagesAfterRemap"] = Self.value(evidence.replacement?.swapped)
    record["purgableStateAfterDiscard"] = Self.value(discarded ? "nonvolatile" : nil)
    return record
  }
  /// Callers prove ownership by a pending REPORTING ACK or the persistent balloon PFN ledger.
  @discardableResult func recycleOwned(
    _ indices: [Int], quiescence: (parked: Bool, epoch: Int, cpus: Int),
    balloonEpoch: UInt64? = nil, acknowledgmentPending: Bool = true
  ) throws -> Bool {
    try confined()
    guard quiescence.parked, quiescence.epoch >= 0, (1...4).contains(quiescence.cpus),
      indices.count <= extents.count, Set(indices).count == indices.count,
      acknowledgmentPending || balloonEpoch.map({ $0 > 0 }) == true,
      indices.allSatisfy({ extents.indices.contains($0) })
    else { throw DeviceFailure.request }
    if quarantined || indices.isEmpty { return false }
    return try retire(
      indices, quiescence: quiescence, replacing: true, balloonEpoch: balloonEpoch,
      acknowledgmentPending: acknowledgmentPending)
  }
  /// Explicit release of every owned kernel resource, only after the native VM stopped running
  /// vCPUs. A failure keeps the remaining resources (and the alias) owned until process exit.
  func close() throws {
    try confined()
    if let aliasAddress {
      try native(mach_vm_deallocate(mach_task_self_, aliasAddress, UInt64(Self.block)))
      self.aliasAddress = nil
    }
    for index in extents.indices {
      let extent = extents[index]
      if extent.mapped {
        try native(hv_vm_unmap(Self.base + UInt64(index * Self.block), Self.block))
        extent.mapped = false
      }
      if let backing = extent.backing {
        try backing.close()
        extent.backing = nil
      }
      if extent.plugged {
        extent.plugged = false
        plugged -= UInt64(Self.block)
      }
      extent.initializedByHost = false
    }
    guard plugged == 0 else { throw DeviceFailure.observation("plugged-accounting") }
  }
}
