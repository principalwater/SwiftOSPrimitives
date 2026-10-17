import BoundedMemory
import Darwin
import Foundation
import Hypervisor
import PageMemory

// Exclusively owned dynamic RAM region, never a borrowed VZ allocation.
final class MemoryDevice {
  static let base: UInt64 = 0x1_0000_0000
  static let block = 2 << 20
  let capacity: Int
  final class Extent {
    var pointer: UnsafeMutableRawPointer?
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
    guard !extent.plugged, !extent.mapped,
      plugged <= UInt64(capacity - Self.block) else { throw DeviceFailure.request }
    extent.freshAllocation = extent.pointer == nil
    if extent.freshAllocation { try native(hv_vm_allocate(&extent.pointer, Self.block, 0)) }
    guard let pointer = extent.pointer else { throw DeviceFailure.request }
    try native(
      mach_vm_inherit(
        mach_task_self_, UInt64(UInt(bitPattern: pointer)), UInt64(Self.block), VM_INHERIT_NONE))
    // Fresh anonymous backing supplies zeroes lazily; reused held pages must be cleared.
    if !coldProvisioning || !extent.freshAllocation {
      memset(pointer, 0, Self.block)
      extent.initializedByHost = true
    } else {
      extent.initializedByHost = false
    }
    // Ordinary Linux RAM: guest stage1 enforces code permissions; host alias stays RW/NX.
    try native(
      hv_vm_map(
        pointer, Self.base + UInt64(index * Self.block), Self.block,
        UInt64(HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC)))
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
  private struct OwnershipRefusal: Error {
    let detail: String
    init(_ detail: String) { self.detail = detail }
  }
  private struct Retirement {
    let index: Int
    let pointer: UnsafeMutableRawPointer
    let info: vm_region_submap_info_data_64_t
    let size: UInt64
  }
  func releaseAlias() throws {
    try confined()
    if let address = aliasAddress {
      try native(mach_vm_deallocate(mach_task_self_, address, UInt64(Self.block)))
      aliasAddress = nil
    }
    aliasReleased = true
  }
  private func inspect(_ index: Int) throws -> Retirement {
    guard let pointer = extents[index].pointer else { throw DeviceFailure.request }
    var address = UInt64(UInt(bitPattern: pointer))
    let original = address
    var size: UInt64 = 0
    var depth: UInt32 = 0
    var info = vm_region_submap_info_data_64_t()
    let words = MemoryLayout<vm_region_submap_info_data_64_t>.size / 4
    var count = mach_msg_type_number_t(words)
    try withUnsafeMutablePointer(to: &info) { value in
      try value.withMemoryRebound(to: integer_t.self, capacity: words) {
        try native(mach_vm_region_recurse(mach_task_self_, &address, &size, &depth, $0, &count))
      }
    }
    guard count == words, address == original, size == Self.block, info.offset == 0,
      info.is_submap == 0,
      info.external_pager == 0, info.shadow_depth == 0, info.object_id_full != 0,
      info.ref_count == 1, info.pages_wired == 0,
      info.user_wired_count == 0
    else {
      throw OwnershipRefusal(
        "index=\(index) start=\(address) original=\(original) size=\(size) offset=\(info.offset) count=\(count) submap=\(info.is_submap) external=\(info.external_pager) shadow=\(info.shadow_depth) object=\(info.object_id_full) refs=\(info.ref_count) swapped=\(info.pages_swapped_out) wired=\(info.pages_wired) userWired=\(info.user_wired_count)"
      )
    }
    return Retirement(index: index, pointer: pointer, info: info, size: size)
  }
  private func restore(_ indices: [Int]) throws {
    for index in indices {
      let extent = extents[index]
      guard let pointer = extent.pointer, extent.plugged, !extent.mapped else {
        throw DeviceFailure.request
      }
      try native(
        hv_vm_map(
          pointer, Self.base + UInt64(index * Self.block), Self.block,
          UInt64(HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC)))
      extent.mapped = true
    }
  }
  private func retire(
    _ indices: [Int], quiescence: (parked: Bool, epoch: Int, cpus: Int), replacing: Bool = false,
    balloonEpoch: UInt64? = nil, acknowledgmentPending: Bool = true
  ) throws -> Bool {
    let remaining = replacing ? recyclingHistory.remainingCounterValues
      : observationHistory.remainingCounterValues
    let cumulative = replacing ? recycledBackingBytes : cumulativeBackingRetiredBytes
    guard !replacing || !held, remaining >= UInt64(indices.count),
      replacing || plugged >= UInt64(indices.count) * UInt64(Self.block),
      UInt64.max - cumulative >= UInt64(indices.count) * UInt64(Self.block),
      indices.allSatisfy({ extents[$0].plugged && extents[$0].mapped && extents[$0].pointer != nil }
      )
    else { throw DeviceFailure.request }
    if indices.contains(where: { extents[$0].metadataPinned }) {
      try refusalHistory.append([
        "reason": "metadata-pinned", "unmappedThenRestored": 0,
        "ownedBytesDeallocated": 0, "reply": replacing ? "REPORT_SKIPPED" : "BUSY",
      ])
      return false
    }
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
    let plans: [Retirement]
    do { plans = try indices.map(inspect) } catch let refusal as OwnershipRefusal {
      // BUSY is legal only before any object has been freed and after full remapping.
      try restore(unmapped)
      try refusalHistory.append([
        "reason": refusal.detail, "unmappedThenRestored": unmapped.count,
        "ownedBytesDeallocated": 0, "reply": replacing ? "REPORT_SKIPPED" : "BUSY",
      ])
      return false
    }
    // Native errors after this point are fatal; released guest data cannot be rolled back.
    for plan in plans {
      let index = plan.index
      let extent = extents[index]
      let before = try ProcessMemorySnapshot.capture()
      let previouslyInitializedByHost = extent.initializedByHost
      let pageSize = Int(sysconf(Int32(_SC_PAGESIZE)))
      guard pageSize > 0, Self.block % pageSize == 0 else { throw DeviceFailure.geometry }
      let residentBefore = UInt64(plan.info.pages_resident) * UInt64(pageSize)
      guard residentBefore <= UInt64(Self.block) else { throw DeviceFailure.geometry }
      if !held {
        try native(hv_vm_deallocate(plan.pointer, Self.block))
        extent.pointer = nil
        try requireAbsent(UInt64(UInt(bitPattern: plan.pointer)))
      }
      var replacementResidentBytes: UInt64?
      if replacing {
        try native(hv_vm_allocate(&extent.pointer, Self.block, 0))
        guard let pointer = extent.pointer else { throw DeviceFailure.request }
        try native(
          mach_vm_inherit(
            mach_task_self_, UInt64(UInt(bitPattern: pointer)), UInt64(Self.block),
            VM_INHERIT_NONE))
        try native(
          hv_vm_map(
            pointer, Self.base + UInt64(index * Self.block), Self.block,
            UInt64(HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC)))
        extent.mapped = true
        extent.freshAllocation = true
        extent.initializedByHost = false
        replacementResidentBytes = try withUnsafeTemporaryAllocation(
          of: Int8.self, capacity: Self.block / pageSize
        ) { pages in
          pages.initialize(repeating: 0)
          guard mincore(pointer, Self.block, pages.baseAddress!) == 0 else {
            throw DeviceFailure.native(errno)
          }
          return pages.reduce(UInt64(0)) { $0 + ($1 & 1 != 0 ? UInt64(pageSize) : 0) }
        }
        // No host writes: fresh anonymous zeroes must remain cold before guest ACK/resume.
        guard replacementResidentBytes == 0 else {
          throw DeviceFailure.observation("replacement-not-cold")
        }
      } else {
        extent.plugged = false
        plugged -= UInt64(Self.block)
      }
      let after = try ProcessMemorySnapshot.capture()
      if replacing {
        recycledBackingBytes += UInt64(Self.block)
        recycledResidentBytes += residentBefore
        if !previouslyInitializedByHost { recycledColdResidentBytes += residentBefore }
      } else if !held {
        cumulativeBackingRetiredBytes += UInt64(Self.block)
      }
      let observation: [String: Any] = [
        "allVCPUsParked": quiescence.parked, "quiescentEpoch": quiescence.epoch,
        "vcpuCount": quiescence.cpus,
        "index": index, "held": held,
        "nativeEntryBytes": plan.size, "nativeObjectOffset": plan.info.offset,
        "freshAllocation": extent.freshAllocation,
        "hostInitializedBytes": previouslyInitializedByHost ? Self.block : 0,
        "residentObservationIncludesHostZeroing": previouslyInitializedByHost,
        "replacementHostInitializedBytes": replacing ? 0 : NSNull(),
        "oldVirtualRangeAbsent": !held,
        "sameGPAMappedBeforeAcknowledgement": replacing && extent.mapped && acknowledgmentPending,
        "sameGPAMappedBeforeResume": replacing && extent.mapped,
        "balloonOwnershipEpoch": balloonEpoch.map { $0 as Any } ?? NSNull(),
        "replacementResidentBytes": replacementResidentBytes.map { $0 as Any } ?? NSNull(),
        "objectID": plan.info.object_id_full,
        "residentPagesBefore": plan.info.pages_resident,
        "pagedOutPagesBefore": plan.info.pages_swapped_out,
        "residentBytesObservedBefore": residentBefore,
        "ownerVirtualBytesDeallocated": held ? 0 : Self.block,
        "referenceCount": plan.info.ref_count,
        "footprintBefore": before.physicalFootprintBytes.map { $0 as Any } ?? NSNull(),
        "footprintAfter": after.physicalFootprintBytes.map { $0 as Any } ?? NSNull(),
        "physicalReleasedBytes": NSNull(),
      ]
      if replacing { try recyclingHistory.append(observation) }
      else { try observationHistory.append(observation) }
    }
    return true
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
  private func requireAbsent(_ original: UInt64) throws {
    var start = original
    var size: UInt64 = 0
    var info = vm_region_basic_info_data_64_t()
    var count = mach_msg_type_number_t(MemoryLayout<vm_region_basic_info_data_64_t>.size / 4)
    var port: mach_port_t = 0
    let result = withUnsafeMutablePointer(to: &info) { value in
      value.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        mach_vm_region(mach_task_self_, &start, &size, VM_REGION_BASIC_INFO_64, $0, &count, &port)
      }
    }
    if port != 0 { try native(mach_port_deallocate(mach_task_self_, port)) }
    guard
      result == KERN_INVALID_ADDRESS
        || result == KERN_SUCCESS && start >= original + UInt64(Self.block)
    else {
      throw DeviceFailure.observation(
        "absence result=\(result) start=\(start) original=\(original) size=\(size)")
    }
  }
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
      if let pointer = extent.pointer {
        try native(hv_vm_deallocate(pointer, Self.block))
        extent.pointer = nil
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
