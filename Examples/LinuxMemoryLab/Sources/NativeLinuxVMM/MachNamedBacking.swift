import Darwin

/// Private owner of one named purgable Mach object and its single host mapping.
///
/// The retained memory-entry send right holds one object reference and the one owner mapping
/// holds the other, so an unshared extent whose stage-2 mapping was removed shows exactly two.
/// Nothing is released implicitly: a vCPU may still be running when an owner becomes unreachable,
/// so there is deliberately no deinit and only `close()` returns kernel resources. Every entry
/// point is confined to the creating thread, and the mapped address is read only by the owning
/// MemoryDevice and its confined payload consumers. Purgable control is per entry and always
/// covers the whole object; one mapping at offset zero of exactly one extent is the only geometry.
final class MachNamedBacking {
  /// Direct counts are in native pages; any other page size is refused rather than converted.
  static let pageBytes: UInt64 = 16384
  static let bytes = UInt64(MemoryDevice.block)
  /// Named entry plus the single owner mapping. A deliberate alias makes three.
  static let exclusiveReferences: UInt32 = 2
  private static let tag = UInt32(VM_MEMORY_APPLICATION_SPECIFIC_1)
  // VM_MAKE_TAG is a function-like macro and is not imported; the tag occupies the top byte.
  private static let tagFlags = Int32(bitPattern: MachNamedBacking.tag << 24)

  /// A guard failed before any object byte was touched, so the caller may restore and refuse.
  struct Refusal: Error {
    let detail: String
  }
  /// Fatal for the VM. A missing native answer is never converted into a zero count.
  enum Failure: Error, Equatable {
    case confinement
    case state(String)
    case native(String, Int32)
    case malformed(String)
  }
  /// Nonfaulting counts of the named object itself, in native pages.
  struct Counts: Equatable {
    let resident: UInt64
    let dirty: UInt64
    let swapped: UInt64
    func residentBytes() throws -> UInt64 {
      let (product, overflow) =
        resident.multipliedReportingOverflow(by: MachNamedBacking.pageBytes)
      guard !overflow else { throw Failure.malformed("resident-bytes \(resident)") }
      return product
    }
  }
  struct Inspection {
    let size: UInt64
    let offset: UInt64
    let objectID: UInt64
    let references: UInt32
    /// Map-walk residency, kept only to compare with the direct counts; never a substitute.
    let regionResidentPages: UInt32
    let counts: Counts
  }
  struct Discard {
    let before: Inspection
    let after: Counts
  }

  private let thread = pthread_self()
  private var entry: mach_port_t
  private var address: UInt64 = 0
  private var identity: UInt64 = 0
  private var poisoned = false

  /// Coordinator-confined host address of the owned mapping; nil while detached or closed.
  var pointer: UnsafeMutableRawPointer? {
    guard pthread_equal(thread, pthread_self()) != 0, !poisoned else { return nil }
    return UnsafeMutableRawPointer(bitPattern: UInt(address))
  }

  private init(entry: mach_port_t) { self.entry = entry }

  /// Explicit confined construction. Every partial resource is released before an error escapes.
  static func create() throws -> MachNamedBacking {
    guard sysconf(Int32(_SC_PAGESIZE)) == Int(pageBytes) else {
      throw Failure.state("native-page-size")
    }
    var size = memory_object_size_t(bytes)
    var entry: mach_port_t = 0
    try checkKernel(
      "make-memory-entry",
      mach_make_memory_entry_64(
        mach_task_self_, &size, 0,
        MAP_MEM_NAMED_CREATE | MAP_MEM_PURGABLE | VM_PROT_READ | VM_PROT_WRITE, &entry, 0))
    let owner = MachNamedBacking(entry: entry)
    do {
      guard entry != 0, size == bytes else {
        throw Failure.malformed("entry=\(entry) size=\(size)")
      }
      try owner.attachMapping()
    } catch { throw owner.cleanup(afterConstruction: error) }
    return owner
  }

  private func cleanup(afterConstruction primary: any Error) -> any Error {
    do { try close() } catch { return Failure.state("\(primary); cleanup \(error)") }
    return primary
  }

  private func cleanup(afterMapping primary: any Error) -> any Error {
    do { try unmapOwned() } catch { return Failure.state("\(primary); unmap \(error)") }
    guard let refusal = primary as? Refusal else { return primary }
    return Failure.state("mapping-invalid \(refusal.detail)")
  }

  private func confined() throws {
    guard pthread_equal(thread, pthread_self()) != 0 else { throw Failure.confinement }
  }

  /// Maps the retained entry as the one host mapping; creation and replug share this path.
  /// The mapping is host read/write, never executable, with a read/write maximum and no fork
  /// inheritance. The address is chosen by the kernel and never supplied by a caller.
  func attachMapping() throws {
    try confined()
    guard entry != 0, address == 0, !poisoned else {
      throw Failure.state("attach: closed, already mapped or poisoned")
    }
    var target: mach_vm_address_t = 0
    try Self.checkKernel(
      "map-entry",
      mach_vm_map(
        mach_task_self_, &target, mach_vm_size_t(Self.bytes), 0,
        VM_FLAGS_ANYWHERE | Self.tagFlags, entry, 0, 0,
        VM_PROT_READ | VM_PROT_WRITE, VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_NONE))
    address = target
    do {
      let (end, overflow) = target.addingReportingOverflow(Self.bytes)
      guard target != 0, target % Self.pageBytes == 0, !overflow, end > target else {
        throw Failure.malformed("mapping-geometry address=\(target)")
      }
      let info = try ownedRegion()
      try requireDiscardable(info)
      // The first verified mapping defines the object identity every later mapping must match.
      if identity == 0 { identity = UInt64(info.object_id_full) }
    } catch { throw cleanup(afterMapping: error) }
  }

  /// Ownership must remain known even during shutdown; a reused address belongs to someone else.
  private func ownedRegion() throws -> vm_region_submap_info_data_64_t {
    var start = address
    var size: UInt64 = 0
    var depth: UInt32 = 0
    var info = vm_region_submap_info_data_64_t()
    let words = MemoryLayout<vm_region_submap_info_data_64_t>.size / MemoryLayout<integer_t>.size
    var count = mach_msg_type_number_t(words)
    let status = withUnsafeMutablePointer(to: &info) { value in
      value.withMemoryRebound(to: integer_t.self, capacity: words) {
        mach_vm_region_recurse(mach_task_self_, &start, &size, &depth, $0, &count)
      }
    }
    guard status == KERN_SUCCESS else {
      poisoned = true
      throw Failure.native("region", status)
    }
    let readWrite = VM_PROT_READ | VM_PROT_WRITE
    // These confined accidental-misuse checks cannot defeat a hostile mutator in the same task.
    guard count == words, start == address, size == Self.bytes, UInt64(info.offset) == 0,
      info.is_submap == 0, UInt32(info.user_tag) == Self.tag,
      info.max_protection == readWrite,
      info.external_pager == 0, info.shadow_depth == 0,
      info.object_id_full != 0, identity == 0 || UInt64(info.object_id_full) == identity
    else {
      poisoned = true
      throw Failure.state(
        "mapping-ownership-lost " + describe(info, start: start, size: size, count: count))
    }
    return info
  }

  /// A known object can refuse destruction without revoking its explicit shutdown ownership.
  private func requireDiscardable(_ info: vm_region_submap_info_data_64_t) throws {
    let readWrite = VM_PROT_READ | VM_PROT_WRITE
    guard info.protection == readWrite,
      UInt32(info.inheritance) == UInt32(VM_INHERIT_NONE),
      UInt32(info.ref_count) == Self.exclusiveReferences,
      info.pages_wired == 0, info.user_wired_count == 0
    else {
      throw Refusal(detail: describe(
        info, start: address, size: Self.bytes,
        count: UInt32(MemoryLayout<vm_region_submap_info_data_64_t>.size / 4)))
    }
  }

  private func describe(
    _ info: vm_region_submap_info_data_64_t, start: UInt64, size: UInt64, count: UInt32
  ) -> String {
    var detail = "start=\(start) expected=\(address) size=\(size) offset=\(info.offset)"
    detail += " count=\(count) submap=\(info.is_submap) tag=\(info.user_tag)"
    detail += " protection=\(info.protection)/\(info.max_protection)"
    detail += " inherit=\(info.inheritance) pager=\(info.external_pager)"
    detail += " shadow=\(info.shadow_depth) object=\(info.object_id_full)"
    detail += " identity=\(identity) refs=\(info.ref_count)"
    detail += " wired=\(info.pages_wired) userWired=\(info.user_wired_count)"
    return detail
  }

  /// The retained send right must still be this process's single user reference.
  private func requireLivePort() throws {
    var references: mach_port_urefs_t = 0
    let status = mach_port_get_refs(mach_task_self_, entry, MACH_PORT_RIGHT_SEND, &references)
    try Self.checkKernel("entry-refs", status)
    guard references == 1 else { throw Refusal(detail: "entry-send-refs=\(references)") }
  }

  private func purgableState() throws -> Int32 {
    var state: Int32 = 0
    try Self.checkKernel(
      "purgable-get-state",
      mach_memory_entry_purgable_control(entry, VM_PURGABLE_GET_STATE, &state))
    return state & VM_PURGABLE_STATE_MASK
  }

  private func setPurgableState(_ requested: Int32) throws {
    var state = requested
    try Self.checkKernel(
      "purgable-set-state",
      mach_memory_entry_purgable_control(entry, VM_PURGABLE_SET_STATE, &state))
  }

  private func pageCounts() throws -> Counts {
    var resident: UInt64 = 0
    var dirty: UInt64 = 0
    var swapped: UInt64 = 0
    try Self.checkKernel(
      "page-counts", mach_memory_entry_get_page_counts(entry, &resident, &dirty, &swapped))
    let pages = Self.bytes / Self.pageBytes
    guard resident <= pages, swapped <= pages, dirty <= resident else {
      throw Failure.malformed("page-counts resident=\(resident) dirty=\(dirty) swapped=\(swapped)")
    }
    return Counts(resident: resident, dirty: dirty, swapped: swapped)
  }

  /// Direct, nonfaulting object counts; a failed query throws and is never read as zero.
  func counts() throws -> Counts {
    try confined()
    guard entry != 0 else { throw Failure.state("counts: closed") }
    return try pageCounts()
  }

  /// Complete ownership validation of the attached mapping, the live entry and its object state.
  /// Refusals leave the object untouched; native query failures are not refusals.
  func inspect() throws -> Inspection {
    try confined()
    guard entry != 0, address != 0, !poisoned else {
      throw Failure.state("inspect: closed, detached or poisoned")
    }
    do {
      let info = try ownedRegion()
      let state = try purgableState()
      guard state == VM_PURGABLE_NONVOLATILE else {
        throw Failure.state("contents-no-longer-protected purgable-state=\(state)")
      }
      // An alias must not hide already-lost contents behind a recoverable refusal.
      try requireLivePort()
      try requireDiscardable(info)
      let counts = try pageCounts()
      return Inspection(
        size: Self.bytes, offset: UInt64(info.offset), objectID: UInt64(info.object_id_full),
        references: UInt32(info.ref_count), regionResidentPages: UInt32(info.pages_resident),
        counts: counts)
    } catch let refusal as Refusal { throw refusal } catch {
      poisoned = true
      throw error
    }
  }

  /// Destroys every byte of the whole object. Ownership is rechecked at this exact point, so a
  /// stale earlier plan can never authorize it; only a `Refusal` before the first destructive
  /// call is recoverable. The caller must already have removed the stage-2 mapping. No byte is
  /// read or written by the host: the after-counts prove the object is cold without warming it.
  func discard() throws -> Discard {
    try confined()
    let before = try inspect()
    // EMPTY is the first destructive step; from here every failure is fatal and sticky.
    poisoned = true
    try setPurgableState(VM_PURGABLE_EMPTY)
    let emptied = try purgableState()
    guard emptied == VM_PURGABLE_EMPTY else { throw Failure.malformed("purgable-empty=\(emptied)") }
    try setPurgableState(VM_PURGABLE_NONVOLATILE)
    let restored = try purgableState()
    guard restored == VM_PURGABLE_NONVOLATILE else {
      throw Failure.malformed("purgable-nonvolatile=\(restored)")
    }
    let after = try pageCounts()
    guard after.resident == 0, after.swapped == 0 else {
      throw Failure.malformed(
        "discard-left-pages resident=\(after.resident) swapped=\(after.swapped)")
    }
    poisoned = false
    return Discard(before: before, after: after)
  }

  private func unmapOwned() throws {
    // A partial construction has just mapped this range; established owners must re-prove it.
    if identity != 0 { _ = try ownedRegion() }
    try Self.checkKernel("unmap-owned", mach_vm_deallocate(mach_task_self_, address, Self.bytes))
    address = 0
  }

  /// Removes only the owned host mapping. The entry and its emptied object stay owned until
  /// `close()`, and any deliberate alias keeps its own mapping.
  func detachMapping() throws {
    try confined()
    guard address != 0, !poisoned else { throw Failure.state("detach: detached or poisoned") }
    let released = address
    try unmapOwned()
    try Self.requireAbsent(released)
  }

  /// The only release of kernel resources, called after the native VM no longer runs vCPUs.
  /// A failure leaves whatever is still owned retained until process retirement.
  func close() throws {
    try confined()
    if address != 0 { try unmapOwned() }
    if entry != 0 {
      try Self.checkKernel("release-entry", mach_port_deallocate(mach_task_self_, entry))
      entry = 0
    }
  }

  private static func requireAbsent(_ original: UInt64) throws {
    let (end, overflow) = original.addingReportingOverflow(bytes)
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
    if port != 0 { try checkKernel("region-port", mach_port_deallocate(mach_task_self_, port)) }
    guard !overflow,
      result == KERN_INVALID_ADDRESS || result == KERN_SUCCESS && start >= end
    else {
      throw Failure.malformed("absence result=\(result) start=\(start) original=\(original)")
    }
  }

  private static func checkKernel(_ operation: String, _ status: kern_return_t) throws {
    guard status == KERN_SUCCESS else { throw Failure.native(operation, status) }
  }
}
