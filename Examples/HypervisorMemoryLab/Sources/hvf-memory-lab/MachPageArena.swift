import Darwin
import Foundation
import Hypervisor

// Private research experiment (see MACH-PAGE-OBJECT-EXPERIMENT.md). The frozen v3 mechanism was
// built and run by the parent; the placeholder safety candidate in this revision is unbuilt and
// unexecuted until the parent proves it. Nothing here is a Linux or ClickHouse result, and nothing
// here is adopted by NativeLinuxVMM or PageMemory.

/// A native API or the ownership proof refused a request this experiment exists to probe. It is a
/// determinate finding, recorded with its operation and native code; nothing unsafe was done in
/// its place and it is never retried.
struct MachPageRefusal: Error {
  let operation: String
  let code: Int32?
  var detail = ""
}

enum MachPageProfile: String {
  case single, pages
  /// Negative modes: per-page layouts that keep one deliberate alias of slot 1 alive past the
  /// check that must see it. Neither may retire any backing, and both must tear down cleanly.
  case pagesAliased = "pages-aliased"
  case pagesPreFreeAliased = "pages-pre-free-aliased"

  /// One independent 16KiB object per slot: every profile except the shared-object control.
  var perPage: Bool {
    switch self {
    case .single: false
    case .pages, .pagesAliased, .pagesPreFreeAliased: true
    }
  }
}

/// Called every 128 slots of a long loop. It throws once the experiment's one absolute deadline
/// has passed and never renews it.
typealias MachPageDeadline = (String) throws -> Void

/// Fixed geometry. Neither the command line nor the environment can supply an address or size.
enum MachPageGeometry {
  static let pageSize = 16384
  static let dataBytes = 64 << 20
  static let pageCount = dataBytes / pageSize
  static let wordsPerPage = pageSize / 8
  static let dataGPA: UInt64 = 0x4000_0000
  static let codeGPA: UInt64 = 0x10_0000
  /// Odd slots are the retirement candidates; even slots are the neighbours that stay live.
  static func isCandidate(_ slot: Int) -> Bool { slot & 1 == 1 }

  /// User tags let a kernel walk tell this experiment's maps apart. APPLICATION_SPECIFIC_1 (240)
  /// marks the reservation and every live object map, APPLICATION_SPECIFIC_2 (241) every
  /// placeholder. They detect accidents only; they are no protection against hostile code in this
  /// task. The flag encoding is the public VM_MAKE_TAG(tag) == tag << 24 under
  /// VM_FLAGS_ALIAS_MASK 0xFF000000, spelled out because Swift does not import the macro.
  static let dataTag = UInt32(VM_MEMORY_APPLICATION_SPECIFIC_1)
  static let placeholderTag = UInt32(VM_MEMORY_APPLICATION_SPECIFIC_2)
  static func tagFlags(_ tag: UInt32) -> Int32 { Int32(bitPattern: tag << 24) }
  static let readWrite = UInt32(VM_PROT_READ | VM_PROT_WRITE)
  static let inaccessible = UInt32(VM_PROT_NONE)
}

/// Deterministic high-entropy page content: every word of every slot can be recomputed.
enum MachPageCanary {
  static func word(slot: Int, index: Int) -> UInt64 {
    var value = (UInt64(slot) << 11 | UInt64(index)) &+ 0x9e37_79b9_7f4a_7c15
    value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
    value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
    return value ^ (value >> 31)
  }
}

/// One kernel map entry reported by `mach_vm_region_recurse`. Every count is the kernel's own
/// report for that entry; none of them is a physical frame observation.
struct MachPageEntry {
  var start: UInt64 = 0
  var length: UInt64 = 0
  var offset: UInt64 = 0
  var objectID: UInt64 = 0
  var references: UInt64 = 0
  var residentPages: UInt64 = 0
  var pagedOutPages: UInt64 = 0
  var wiredPages: UInt64 = 0
  var userWired: UInt64 = 0
  var shadowDepth: UInt64 = 0
  var externalPager: UInt64 = 0
  var protection: UInt32 = 0
  var maximumProtection: UInt32 = 0
  var tag: UInt32 = 0
  var shareMode: UInt32 = 0
  var submap = false
  var end: UInt64 { start &+ length }
}

struct MachPageRegion {
  var code: kern_return_t = KERN_FAILURE
  var complete = false
  var entry = MachPageEntry()
}

struct MachPageDispositions {
  var pages = 0
  var present = 0
  var pagedOut = 0
  var reusable = 0
  var anomalous = 0
  var json: [String: Any] {
    [
      "pagesQueried": pages, "present": present, "pagedOutOrCompressed": pagedOut,
      "reusable": reusable, "fictitiousCopiedOrExternal": anomalous,
    ]
  }
}

/// Every raw Mach call of the experiment lives here. Native codes are returned or thrown
/// unchanged so a changed SDK signature has exactly one place to fix.
enum MachPageKernel {
  /// Owns a whole anonymous virtual range first; later mappings may only land inside it.
  static func reserve(bytes: Int) throws -> UInt64 {
    var address: mach_vm_address_t = 0
    let code = mach_vm_allocate(
      mach_task_self_, &address, mach_vm_size_t(bytes),
      VM_FLAGS_ANYWHERE | MachPageGeometry.tagFlags(MachPageGeometry.dataTag))
    guard code == KERN_SUCCESS else { throw Failure.native("reserve-arena", code) }
    guard address % UInt64(MachPageGeometry.pageSize) == 0 else {
      _ = mach_vm_deallocate(mach_task_self_, address, mach_vm_size_t(bytes))
      throw Failure.geometry
    }
    return address
  }

  /// Creates a brand-new named memory object. The returned send right must be released.
  static func makeEntry(bytes: Int) throws -> mach_port_t {
    var size = memory_object_size_t(bytes)
    var port: mach_port_t = 0
    let code = mach_make_memory_entry_64(
      mach_task_self_, &size, 0, MAP_MEM_NAMED_CREATE | VM_PROT_READ | VM_PROT_WRITE, &port, 0)
    guard code == KERN_SUCCESS else {
      throw MachPageRefusal(operation: "mach_make_memory_entry_64", code: code)
    }
    guard port != 0, size == memory_object_size_t(bytes) else {
      if port != 0 { _ = mach_port_deallocate(mach_task_self_, port) }
      throw Failure.observation
    }
    return port
  }

  /// Maps the named object, never copying it. The replacement is unconditional, so the caller
  /// must already have proven it owns the whole destination: the initial reservation (checked
  /// when it was made) or a placeholder the kernel just reported unchanged.
  static func map(_ port: mach_port_t, at address: UInt64, bytes: Int) -> kern_return_t {
    var target = address
    return mach_vm_map(
      mach_task_self_, &target, mach_vm_size_t(bytes), 0,
      VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE | MachPageGeometry.tagFlags(MachPageGeometry.dataTag),
      port, 0, 0, VM_PROT_READ | VM_PROT_WRITE, VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_NONE)
  }

  /// Anonymous zero-fill, inaccessible stand-in for one retired slot. With `replacing` the old
  /// mapping is swapped out inside this one kernel call, so the address is never free in between
  /// (a separate deallocate and reserve would leave a window for another allocation). Without it
  /// the call can only claim free space, which is how the claim control proves a placeholder is
  /// owned. Both use identical protection, tag and inheritance.
  static func placeholder(at address: UInt64, bytes: Int, replacing: Bool) -> kern_return_t {
    var target = address
    var flags = VM_FLAGS_FIXED | MachPageGeometry.tagFlags(MachPageGeometry.placeholderTag)
    if replacing { flags |= VM_FLAGS_OVERWRITE }
    return mach_vm_map(
      mach_task_self_, &target, mach_vm_size_t(bytes), 0, flags, mach_port_t(MACH_PORT_NULL), 0, 0,
      VM_PROT_NONE, VM_PROT_NONE, VM_INHERIT_NONE)
  }

  static func release(_ port: mach_port_t) -> kern_return_t {
    mach_port_deallocate(mach_task_self_, port)
  }

  static func deallocate(_ address: UInt64, bytes: Int) -> kern_return_t {
    mach_vm_deallocate(mach_task_self_, address, mach_vm_size_t(bytes))
  }

  /// A second mapping of the same object, used only by the bounded alias controls. It is not
  /// tagged: remap accepts no user tag in its flags.
  static func alias(of address: UInt64, bytes: Int) -> (code: kern_return_t, address: UInt64) {
    var target: mach_vm_address_t = 0
    var current: vm_prot_t = 0
    var maximum: vm_prot_t = 0
    let code = mach_vm_remap(
      mach_task_self_, &target, mach_vm_size_t(bytes), 0, VM_FLAGS_ANYWHERE, mach_task_self_,
      address, 0, &current, &maximum, VM_INHERIT_NONE)
    return (code, target)
  }

  /// The first map entry at or after `address`, with the SDK27 submap layout requested in full.
  static func region(from address: UInt64) -> MachPageRegion {
    var start = address
    var length: mach_vm_size_t = 0
    var depth: natural_t = 0
    var info = vm_region_submap_info_data_64_t()
    let capacity = MemoryLayout<vm_region_submap_info_data_64_t>.size / MemoryLayout<integer_t>.size
    var count = mach_msg_type_number_t(capacity)
    let code = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
        mach_vm_region_recurse(mach_task_self_, &start, &length, &depth, $0, &count)
      }
    }
    var region = MachPageRegion()
    region.code = code
    guard code == KERN_SUCCESS else { return region }
    region.complete = Int(count) == capacity
    var entry = MachPageEntry()
    entry.start = start
    entry.length = length
    entry.offset = info.offset
    entry.objectID = info.object_id_full
    entry.references = UInt64(truncatingIfNeeded: info.ref_count)
    entry.residentPages = UInt64(truncatingIfNeeded: info.pages_resident)
    entry.pagedOutPages = UInt64(truncatingIfNeeded: info.pages_swapped_out)
    entry.wiredPages = UInt64(truncatingIfNeeded: info.pages_wired)
    entry.userWired = UInt64(truncatingIfNeeded: info.user_wired_count)
    entry.shadowDepth = UInt64(truncatingIfNeeded: info.shadow_depth)
    entry.externalPager = UInt64(truncatingIfNeeded: info.external_pager)
    entry.protection = UInt32(truncatingIfNeeded: info.protection)
    entry.maximumProtection = UInt32(truncatingIfNeeded: info.max_protection)
    entry.tag = UInt32(truncatingIfNeeded: info.user_tag)
    entry.shareMode = UInt32(truncatingIfNeeded: info.share_mode)
    entry.submap = info.is_submap != 0
    region.entry = entry
    return region
  }
}

/// Exclusive owner of one 64MiB host virtual reservation, the Mach objects that back its 16KiB
/// slots, and the matching guest-physical window. Every mutation first asks the machine to
/// confirm it runs on the thread that owns the VM and its only vCPU, outside `hv_vcpu_run`.
///
/// Ownership contract
/// - Mach memory is released only with Mach calls and HVF mappings only with HVF calls. This
///   type never passes arena memory to `hv_vm_deallocate`.
/// - A slot is retired only while it is not mapped into the guest, and only after a proof taken
///   immediately before the retirement shows it is still this arena's object.
/// - A retired slot is never a hole. One kernel call swaps its object for an inaccessible
///   placeholder, so the address stays claimed. A placeholder is replaced only after the kernel
///   reports it is still the placeholder made for that slot; a foreign mapping is never replaced
///   or freed. Allocator separation is unchanged: code page, data objects and placeholders are
///   distinct mappings and only Mach calls release the arena.
/// - Temporary memory-entry ports are released immediately after the mapping call.
/// - A deliberate alias is tracked the moment it exists and forgotten only when its drop is
///   confirmed. Tags, identifiers and protections detect accidents; they are not security against
///   hostile code in this task, so the owner thread, a quiescent vCPU and trusted access remain
///   required.
final class MachPageArena {
  enum Slot: UInt8 { case reserved, owned, placeholder, released }
  enum GuestMapping { case unmapped, whole, fragmented }

  /// A second mapping of one slot's object, outside the arena.
  struct Alias {
    let slot: Int
    let address: UInt64
  }

  /// What the kernel reported for a placeholder right after it replaced the slot's object. Later
  /// checks must reproduce it exactly, so any change of the entry behind it is noticed.
  struct PlaceholderState: Equatable {
    var objectID: UInt64
    var references: UInt64
    var shareMode: UInt32
    init(_ entry: MachPageEntry) {
      objectID = entry.objectID
      references = entry.references
      shareMode = entry.shareMode
    }
  }

  let profile: MachPageProfile
  let base: UInt64
  private let machine: Machine
  private(set) var slots = [Slot](repeating: .reserved, count: MachPageGeometry.pageCount)
  /// Identifier of each slot's live object, zero once retired. Identifiers are recycled, so this
  /// is one check among several and never proof of identity by itself.
  private(set) var objectIDs = [UInt64](repeating: 0, count: MachPageGeometry.pageCount)
  /// Evidence only: the identifier each retired slot's object had, one entry per slot written at
  /// retirement. No ownership decision may consult it.
  private(set) var retiredObjectIDs = [UInt64](repeating: 0, count: MachPageGeometry.pageCount)
  private var placeholderStates = [PlaceholderState?](
    repeating: nil, count: MachPageGeometry.pageCount)
  private(set) var aliases: [Alias] = []
  private(set) var guestMapped = [Bool](repeating: false, count: MachPageGeometry.pageCount)
  private(set) var guestMapping = GuestMapping.unmapped
  private(set) var released = false

  private init(profile: MachPageProfile, base: UInt64, machine: Machine) {
    self.profile = profile
    self.base = base
    self.machine = machine
  }

  /// Reserves the range, then proves the kernel reports it as one tagged read/write entry. A
  /// range that does not verify is returned at once: it was allocated by the call above.
  static func reserve(profile: MachPageProfile, machine: Machine) throws -> MachPageArena {
    try machine.confined()
    guard sysconf(Int32(_SC_PAGESIZE)) == MachPageGeometry.pageSize else { throw Failure.geometry }
    let base = try MachPageKernel.reserve(bytes: MachPageGeometry.dataBytes)
    let region = MachPageKernel.region(from: base)
    let entry = region.entry
    guard region.code == KERN_SUCCESS, region.complete, !entry.submap, entry.start <= base,
      entry.end >= base + UInt64(MachPageGeometry.dataBytes),
      entry.tag == MachPageGeometry.dataTag, entry.protection == MachPageGeometry.readWrite
    else {
      _ = MachPageKernel.deallocate(base, bytes: MachPageGeometry.dataBytes)
      throw Failure.experiment(
        "reservation: code \(region.code) start \(entry.start) end \(entry.end) "
          + "tag \(entry.tag) protection \(entry.protection)")
    }
    return MachPageArena(profile: profile, base: base, machine: machine)
  }

  func address(of slot: Int) -> UInt64 { base + UInt64(slot * MachPageGeometry.pageSize) }
  func guestAddress(of slot: Int) -> UInt64 {
    MachPageGeometry.dataGPA + UInt64(slot * MachPageGeometry.pageSize)
  }

  /// SINGLE: one 64MiB object. Per-page profiles: 4096 independent 16KiB objects. All replace
  /// only the reservation this arena already owns.
  func install(deadline: MachPageDeadline) throws {
    try machine.confined()
    guard slots.allSatisfy({ $0 == .reserved }) else { throw Failure.state }
    guard profile.perPage else {
      try place(
        bytes: MachPageGeometry.dataBytes, at: base, covering: 0..<MachPageGeometry.pageCount,
        operation: "mach_vm_map(install)")
      return
    }
    for slot in 0..<MachPageGeometry.pageCount {
      if slot & 127 == 0 { try deadline("object install") }
      try place(
        bytes: MachPageGeometry.pageSize, at: address(of: slot), covering: slot..<(slot + 1),
        operation: "mach_vm_map(install)")
    }
  }

  private func place(
    bytes: Int, at location: UInt64, covering range: Range<Int>, operation: String
  ) throws {
    let port = try MachPageKernel.makeEntry(bytes: bytes)
    let mapped = MachPageKernel.map(port, at: location, bytes: bytes)
    let freed = MachPageKernel.release(port)
    guard mapped == KERN_SUCCESS else {
      throw MachPageRefusal(
        operation: operation, code: mapped,
        detail: freed == KERN_SUCCESS ? "" : "memory-entry release returned \(freed)")
    }
    for slot in range {
      slots[slot] = .owned
      placeholderStates[slot] = nil
    }
    guard freed == KERN_SUCCESS else { throw Failure.native("release-memory-entry", freed) }
  }

  /// Map entries that intersect the reservation, in address order. Holes are not entries.
  func entries() throws -> [MachPageEntry] {
    var result: [MachPageEntry] = []
    result.reserveCapacity(MachPageGeometry.pageCount + 1)
    let limit = base + UInt64(MachPageGeometry.dataBytes)
    var cursor = base
    while cursor < limit {
      let region = MachPageKernel.region(from: cursor)
      if region.code == KERN_INVALID_ADDRESS { break }
      guard region.code == KERN_SUCCESS else { throw Failure.native("arena-region", region.code) }
      guard region.complete, !region.entry.submap, region.entry.end > cursor else {
        throw Failure.observation
      }
      if region.entry.start >= limit { break }
      result.append(region.entry)
      cursor = region.entry.end
    }
    return result
  }

  /// The entry containing `address`, if any. `entries` must be in address order.
  static func covering(_ address: UInt64, in entries: [MachPageEntry]) -> MachPageEntry? {
    var low = 0
    var high = entries.count
    while low < high {
      let middle = (low + high) / 2
      if entries[middle].end <= address { low = middle + 1 } else { high = middle }
    }
    guard low < entries.count, entries[low].start <= address else { return nil }
    return entries[low]
  }

  /// Tag and protection of a live object map, as requested when it was mapped.
  private static func isDataMap(_ entry: MachPageEntry) -> Bool {
    entry.tag == MachPageGeometry.dataTag && entry.protection == MachPageGeometry.readWrite
      && entry.maximumProtection == MachPageGeometry.readWrite
  }

  /// Proves the kernel agrees with the requested object layout and records every identity.
  /// SINGLE must be one exactly shared object; per-page profiles must be fully independent
  /// objects, each referenced once (which also shows every temporary memory-entry port was
  /// released). Every entry must carry the arena's tag with read/write protection.
  func verifyInstalled(_ entries: [MachPageEntry]) throws {
    let bytes = UInt64(MachPageGeometry.dataBytes)
    let page = UInt64(MachPageGeometry.pageSize)
    guard profile.perPage else {
      guard entries.count == 1, let entry = entries.first, entry.start == base,
        entry.length == bytes
      else {
        throw Failure.experiment("single: kernel reported \(entries.count) entries, expected one")
      }
      guard entry.offset == 0, entry.objectID != 0, entry.references == 1, !entry.submap,
        Self.isDataMap(entry)
      else {
        throw Failure.experiment(
          "single: offset=\(entry.offset) object=\(entry.objectID) references=\(entry.references) "
            + "tag=\(entry.tag) protection=\(entry.protection)/\(entry.maximumProtection)")
      }
      for slot in objectIDs.indices { objectIDs[slot] = entry.objectID }
      return
    }
    guard entries.count == MachPageGeometry.pageCount else {
      throw Failure.experiment("pages: kernel reported \(entries.count) entries, expected 4096")
    }
    var identities = Set<UInt64>()
    for (slot, entry) in entries.enumerated() {
      guard entry.start == address(of: slot), entry.length == page, entry.offset == 0,
        entry.objectID != 0, entry.references == 1, !entry.submap, Self.isDataMap(entry)
      else {
        throw Failure.experiment(
          "pages: slot \(slot) length=\(entry.length) offset=\(entry.offset) "
            + "object=\(entry.objectID) references=\(entry.references) tag=\(entry.tag) "
            + "protection=\(entry.protection)/\(entry.maximumProtection)")
      }
      identities.insert(entry.objectID)
      objectIDs[slot] = entry.objectID
    }
    guard identities.count == MachPageGeometry.pageCount else {
      throw Failure.experiment("pages: only \(identities.count) distinct object identifiers")
    }
  }

  /// Controlled first touch: writes the canary into every word of every slot from the host.
  func fill(deadline: MachPageDeadline) throws {
    try machine.confined()
    guard slots.allSatisfy({ $0 == .owned }),
      let words = UnsafeMutablePointer<UInt64>(bitPattern: UInt(base))
    else { throw Failure.state }
    for slot in 0..<MachPageGeometry.pageCount {
      if slot & 127 == 0 { try deadline("host fill") }
      let page = words + slot * MachPageGeometry.wordsPerPage
      for index in 0..<MachPageGeometry.wordsPerPage {
        page[index] = MachPageCanary.word(slot: slot, index: index)
      }
    }
  }

  /// Full-page host comparison of a live slot against its canary, or against zero.
  func hostMismatches(slot: Int, zero: Bool) throws -> Int {
    guard slots[slot] == .owned,
      let words = UnsafePointer<UInt64>(bitPattern: UInt(address(of: slot)))
    else { throw Failure.state }
    var mismatches = 0
    for index in 0..<MachPageGeometry.wordsPerPage {
      let expected = zero ? 0 : MachPageCanary.word(slot: slot, index: index)
      if words[index] != expected { mismatches += 1 }
    }
    return mismatches
  }

  /// Returns nil when the page is provably this arena's, otherwise the first refusal reason.
  /// Per-page profiles also require an exclusive 16KiB object (one reference). SINGLE cannot:
  /// its object is shared by construction, so only identity, tag, protection, offset and wiring
  /// are enforced there, and passing never means the retired offset held the last reference.
  func ownershipRefusal(_ slot: Int, entry: MachPageEntry?) -> String? {
    guard let entry else { return "slot \(slot) has no covering map entry" }
    let page = UInt64(MachPageGeometry.pageSize)
    let location = self.address(of: slot)
    guard !entry.submap, entry.start <= location, entry.end >= location + page else {
      return "slot \(slot) is not covered by one plain map entry"
    }
    guard Self.isDataMap(entry) else {
      return "slot \(slot) tag \(entry.tag) protection "
        + "\(entry.protection)/\(entry.maximumProtection) is not an arena object map"
    }
    guard entry.objectID != 0, entry.objectID == objectIDs[slot] else {
      return "slot \(slot) object \(entry.objectID) differs from recorded \(objectIDs[slot])"
    }
    let objectOffset = entry.offset + (location - entry.start)
    guard objectOffset == (profile == .single ? UInt64(slot) * page : 0) else {
      return "slot \(slot) object offset \(objectOffset)"
    }
    guard entry.shadowDepth == 0, entry.externalPager == 0, entry.wiredPages == 0,
      entry.userWired == 0
    else { return "slot \(slot) has shadow, pager or wiring state" }
    if profile.perPage {
      guard entry.start == location, entry.length == page, entry.references == 1 else {
        return "slot \(slot) is not an exclusive 16KiB object (references \(entry.references))"
      }
    }
    return nil
  }

  struct Preflight {
    var examined = 0
    var refused = 0
    var minimumReferences = UInt64.max
    var maximumReferences: UInt64 = 0
    var examples: [String] = []
    var json: [String: Any] {
      var result: [String: Any] = [:]
      result["examinedPages"] = examined
      result["refusedPages"] = refused
      result["minimumReferences"] = MachPageJSON.orNull(
        minimumReferences == .max ? nil : minimumReferences)
      result["maximumReferences"] = maximumReferences
      result["refusalExamples"] = examples
      return result
    }
  }

  /// Checks every candidate before any of them is retired (all-or-nothing, like BUSY). This bulk
  /// proof goes stale during the guest probes; `retire` repeats it for each slot.
  func preflight(_ candidates: [Int], entries: [MachPageEntry]) -> Preflight {
    var result = Preflight()
    for slot in candidates {
      let entry = Self.covering(address(of: slot), in: entries)
      result.examined += 1
      if let entry {
        result.minimumReferences = min(result.minimumReferences, entry.references)
        result.maximumReferences = max(result.maximumReferences, entry.references)
      }
      if let reason = ownershipRefusal(slot, entry: entry) {
        result.refused += 1
        if result.examples.count < 4 { result.examples.append(reason) }
      }
    }
    return result
  }

  struct AliasControl {
    var kept = false
    var referencesWhileAliased: UInt64 = 0
    var refusedWhileAliased = false
    var refusalReason = ""
    var referencesAfterDrop: UInt64?
    var acceptedAfterDrop: Bool?
    /// A kept alias only has to be seen by the proof; a dropped one must also be forgotten by it.
    var valid: Bool { refusedWhileAliased && (kept || acceptedAfterDrop == true) }
    var json: [String: Any] {
      var result: [String: Any] = [:]
      result["aliasKeptUntilTeardown"] = kept
      result["referencesWhileAliased"] = referencesWhileAliased
      result["ownershipProofRefusedWhileAliased"] = refusedWhileAliased
      result["refusalReason"] = refusalReason
      result["referencesAfterDrop"] = MachPageJSON.orNull(referencesAfterDrop)
      result["ownershipProofAcceptedAfterDrop"] = MachPageJSON.orNull(acceptedAfterDrop)
      return result
    }
  }

  private func query(slot: Int) -> MachPageEntry? {
    let region = MachPageKernel.region(from: address(of: slot))
    return region.code == KERN_SUCCESS && region.complete ? region.entry : nil
  }

  /// Maps a second view of one slot's object and records it before anything else can fail.
  private func makeAlias(slot: Int) throws -> Alias {
    try machine.confined()
    guard profile.perPage, slots[slot] == .owned, !guestMapped[slot], aliases.isEmpty else {
      throw Failure.state
    }
    let made = MachPageKernel.alias(of: address(of: slot), bytes: MachPageGeometry.pageSize)
    guard made.code == KERN_SUCCESS else { throw Failure.native("alias-create", made.code) }
    let alias = Alias(slot: slot, address: made.address)
    aliases.append(alias)
    return alias
  }

  /// The alias leaves the ledger only when the kernel confirms the drop, so a failed drop is
  /// still known to teardown.
  private func dropAlias(_ alias: Alias) throws {
    let code = MachPageKernel.deallocate(alias.address, bytes: MachPageGeometry.pageSize)
    guard code == KERN_SUCCESS else { throw Failure.native("alias-drop", code) }
    aliases.removeAll { $0.address == alias.address }
  }

  /// Bounded refusal control (per-page profiles, one candidate): while a second mapping of the
  /// page's object exists the ownership proof must refuse. Unless `keep` is set, dropping it must
  /// restore exclusivity; a kept alias stays tracked until teardown drops it. The aliased page is
  /// never retired by this control.
  func aliasControl(slot: Int, keep: Bool) throws -> AliasControl {
    let alias = try makeAlias(slot: slot)
    var control = AliasControl()
    control.kept = keep
    let aliased = query(slot: slot)
    control.referencesWhileAliased = aliased?.references ?? 0
    let refusal = ownershipRefusal(slot, entry: aliased)
    control.refusedWhileAliased = refusal != nil
    control.refusalReason = refusal ?? ""
    guard !keep else { return control }
    try dropAlias(alias)
    let restored = query(slot: slot)
    control.referencesAfterDrop = restored?.references ?? 0
    control.acceptedAfterDrop = ownershipRefusal(slot, entry: restored) == nil
    return control
  }

  /// Neighbours must keep their recorded object, still be owned, and still be mapped.
  func neighborMismatches(entries: [MachPageEntry]) -> Int {
    var mismatches = 0
    for slot in 0..<MachPageGeometry.pageCount where !MachPageGeometry.isCandidate(slot) {
      let entry = Self.covering(address(of: slot), in: entries)
      if slots[slot] != .owned || entry?.objectID == 0 || entry?.objectID != objectIDs[slot] {
        mismatches += 1
      }
    }
    return mismatches
  }

  /// Slots with no covering map entry, that is, holes. A retired slot must never be one.
  func absentCount(_ candidates: [Int], entries: [MachPageEntry]) -> Int {
    candidates.filter { Self.covering(address(of: $0), in: entries) == nil }.count
  }

  struct PlaceholderAudit {
    var verified = 0
    var refused = 0
    var examples: [String] = []
    var json: [String: Any] {
      [
        "verifiedPlaceholders": verified, "refusedPlaceholders": refused,
        "refusalExamples": examples,
      ]
    }
  }

  /// Returns nil when the slot is still the inaccessible placeholder made for it: one exact
  /// 16KiB entry with the placeholder tag, no access, no pages, no shadow, pager or wiring, and,
  /// once a first observation is recorded, the same object identifier, references and share mode.
  func placeholderRefusal(_ slot: Int, entry: MachPageEntry?) -> String? {
    guard slots[slot] == .placeholder else { return "slot \(slot) is not a placeholder" }
    guard let entry else { return "slot \(slot) has no covering map entry" }
    guard !entry.submap, entry.start == address(of: slot),
      entry.length == UInt64(MachPageGeometry.pageSize)
    else { return "slot \(slot) is not one exact 16KiB map entry" }
    guard entry.tag == MachPageGeometry.placeholderTag,
      entry.protection == MachPageGeometry.inaccessible,
      entry.maximumProtection == MachPageGeometry.inaccessible
    else {
      return "slot \(slot) tag \(entry.tag) protection "
        + "\(entry.protection)/\(entry.maximumProtection) is not a placeholder map"
    }
    guard entry.residentPages == 0, entry.pagedOutPages == 0, entry.wiredPages == 0,
      entry.userWired == 0, entry.shadowDepth == 0, entry.externalPager == 0
    else { return "slot \(slot) placeholder has page, shadow, pager or wiring state" }
    if let recorded = placeholderStates[slot], recorded != PlaceholderState(entry) {
      return "slot \(slot) placeholder changed since it was made"
    }
    return nil
  }

  /// Audits every listed placeholder against one kernel walk. With `record`, each first
  /// observation becomes the state later checks must reproduce. A placeholder reporting an
  /// object identifier a live slot maps cannot be a fresh anonymous object and is refused.
  func auditPlaceholders(
    _ candidates: [Int], entries: [MachPageEntry], record: Bool
  ) -> PlaceholderAudit {
    var result = PlaceholderAudit()
    let live = Set(objectIDs.filter { $0 != 0 })
    for slot in candidates {
      let entry = Self.covering(address(of: slot), in: entries)
      var reason = placeholderRefusal(slot, entry: entry)
      if reason == nil, record, let entry {
        if live.contains(entry.objectID) {
          reason = "slot \(slot) placeholder shares object \(entry.objectID) with a live slot"
        } else {
          placeholderStates[slot] = PlaceholderState(entry)
        }
      }
      if let reason {
        result.refused += 1
        if result.examples.count < 4 { result.examples.append(reason) }
      } else {
        result.verified += 1
      }
    }
    return result
  }

  /// Retires one page: its object mapping is swapped for an inaccessible placeholder in a single
  /// kernel call, so the address is never unclaimed. The caller has already unmapped it from the
  /// guest. Nothing here is physical release; it only drops this mapping's reference.
  func retire(_ slot: Int) throws {
    try machine.confined()
    guard slots[slot] == .owned, !guestMapped[slot] else { throw Failure.state }
    // The bulk proof ran before thousands of vCPU runs. Prove this slot again immediately
    // before the point of no return, so a late alias, shadow or foreign remap is refused.
    if let reason = ownershipRefusal(slot, entry: query(slot: slot)) {
      throw MachPageRefusal(operation: "ownership-proof(retire)", code: nil, detail: reason)
    }
    let code = MachPageKernel.placeholder(
      at: address(of: slot), bytes: MachPageGeometry.pageSize, replacing: true)
    guard code == KERN_SUCCESS else {
      throw MachPageRefusal(operation: "mach_vm_map(placeholder)", code: code)
    }
    slots[slot] = .placeholder
    // The old identifier moves to the evidence ledger; the slot's next object gets its own.
    retiredObjectIDs[slot] = objectIDs[slot]
    objectIDs[slot] = 0
  }

  struct ClaimControl {
    var slot = 0
    var nativeCode = KERN_SUCCESS
    var placeholderUnchanged = false
    var refused: Bool { nativeCode != KERN_SUCCESS }
    var valid: Bool { refused && placeholderUnchanged }
    var json: [String: Any] {
      var result: [String: Any] = [:]
      result["slot"] = slot
      result["nativeCode"] = Int(nativeCode)
      result["expectedNativeCode"] = Int(KERN_NO_SPACE)
      result["claimRefusedWhileOwned"] = refused
      result["placeholderUnchangedAfter"] = placeholderUnchanged
      return result
    }
  }

  /// Native control for the placeholder claim: a request for the placeholder's own range with
  /// identical parameters, but without OVERWRITE, must be refused while the placeholder is
  /// owned. Nothing is replaced or freed. If the kernel accepted it the range was not owned: the
  /// slot stays a tracked placeholder, the control is invalid and teardown verifies it again.
  func placeholderClaimControl(slot: Int) throws -> ClaimControl {
    try machine.confined()
    guard slots[slot] == .placeholder, placeholderStates[slot] != nil, !guestMapped[slot] else {
      throw Failure.state
    }
    var control = ClaimControl()
    control.slot = slot
    control.nativeCode = MachPageKernel.placeholder(
      at: address(of: slot), bytes: MachPageGeometry.pageSize, replacing: false)
    control.placeholderUnchanged = placeholderRefusal(slot, entry: query(slot: slot)) == nil
    return control
  }

  /// Fresh zero-fill object over one placeholder this arena made. The overwrite is unconditional,
  /// so the kernel must first report the slot is still exactly that placeholder; a foreign
  /// mapping is refused, never replaced.
  func refill(_ slot: Int) throws {
    try machine.confined()
    guard slots[slot] == .placeholder, !guestMapped[slot], placeholderStates[slot] != nil else {
      throw Failure.state
    }
    if let reason = placeholderRefusal(slot, entry: query(slot: slot)) {
      throw MachPageRefusal(operation: "placeholder-proof(refill)", code: nil, detail: reason)
    }
    try place(
      bytes: MachPageGeometry.pageSize, at: address(of: slot), covering: slot..<(slot + 1),
      operation: "mach_vm_map(refill)")
  }

  /// Proves refilled slots are fresh exclusive arena objects, unlike every live neighbour, and
  /// records their identities as a new lifetime. Returns how many reuse an identifier of a
  /// just-retired object (evidence of object death, never a reason to trust an identifier).
  func verifyRefilled(
    _ entries: [MachPageEntry], slots refilled: [Int], retired: Set<UInt64>
  ) throws -> Int {
    let page = UInt64(MachPageGeometry.pageSize)
    var neighbours = Set<UInt64>()
    for slot in 0..<MachPageGeometry.pageCount where slots[slot] == .owned && objectIDs[slot] != 0 {
      neighbours.insert(objectIDs[slot])
    }
    var fresh = Set<UInt64>()
    for slot in refilled {
      let location = address(of: slot)
      // The last condition records uniqueness among the refilled objects themselves.
      guard let entry = Self.covering(location, in: entries), entry.start == location,
        entry.length == page, entry.offset == 0, entry.objectID != 0, entry.references == 1,
        !entry.submap, Self.isDataMap(entry), !neighbours.contains(entry.objectID),
        fresh.insert(entry.objectID).inserted
      else { throw Failure.experiment("refill: slot \(slot) is not a fresh exclusive object") }
      objectIDs[slot] = entry.objectID
    }
    return fresh.intersection(retired).count
  }

  /// One contiguous HVF mapping over every host object. HVF may refuse it; that is a finding.
  func mapGuestWhole() throws {
    try machine.confined()
    guard guestMapping == .unmapped, slots.allSatisfy({ $0 == .owned }),
      let pointer = UnsafeMutableRawPointer(bitPattern: UInt(base))
    else { throw Failure.state }
    let code = hv_vm_map(
      pointer, MachPageGeometry.dataGPA, MachPageGeometry.dataBytes,
      UInt64(HV_MEMORY_READ | HV_MEMORY_WRITE))
    guard code == HV_SUCCESS else {
      throw MachPageRefusal(operation: "hv_vm_map(data)", code: code)
    }
    guestMapping = .whole
    for slot in guestMapped.indices { guestMapped[slot] = true }
  }

  /// Unmaps one 16KiB sub-range of the earlier contiguous mapping. HVF may refuse that too.
  func unmapGuest(slot: Int) throws {
    try machine.confined()
    guard guestMapped[slot], guestMapping != .unmapped else { throw Failure.state }
    let code = hv_vm_unmap(guestAddress(of: slot), MachPageGeometry.pageSize)
    guard code == HV_SUCCESS else {
      throw MachPageRefusal(operation: "hv_vm_unmap(page)", code: code)
    }
    guestMapping = .fragmented
    guestMapped[slot] = false
  }

  func mapGuest(slot: Int) throws {
    try machine.confined()
    guard slots[slot] == .owned, !guestMapped[slot], guestMapping == .fragmented,
      let pointer = UnsafeMutableRawPointer(bitPattern: UInt(address(of: slot)))
    else { throw Failure.state }
    let code = hv_vm_map(
      pointer, guestAddress(of: slot), MachPageGeometry.pageSize,
      UInt64(HV_MEMORY_READ | HV_MEMORY_WRITE))
    guard code == HV_SUCCESS else {
      throw MachPageRefusal(operation: "hv_vm_map(page)", code: code)
    }
    guestMapped[slot] = true
  }

  struct Release {
    var aliasesRetained = 0
    var aliasesDropped = 0
    var guestUnmapped = 0
    var hostDeallocated = 0
    var placeholdersDeallocated = 0
    var hostSkipped = 0
    var errors: [String] = []
    var json: [String: Any] {
      [
        "aliasesRetained": aliasesRetained, "aliasesDropped": aliasesDropped,
        "guestPagesUnmapped": guestUnmapped, "hostPagesDeallocated": hostDeallocated,
        "placeholderPagesDeallocated": placeholdersDeallocated,
        "hostPagesSkipped": hostSkipped, "errors": errors,
      ]
    }
  }

  /// Ownership-order cleanup after the vCPU is confirmed destroyed: every retained alias first,
  /// then guest mappings, then host memory. Nothing stops at the first failure and each one is
  /// reported. It never frees a page that is still guest-mapped, nor a placeholder the kernel no
  /// longer reports as the one made for that slot. Placeholders are owned address space, so they
  /// are released here like live slots; none is left claimed.
  func release() -> Release {
    var result = Release()
    do { try machine.confined() } catch {
      result.errors.append("release is not on the owner thread or a vCPU run is open: \(error)")
      return result
    }
    result.aliasesRetained = aliases.count
    for alias in aliases {
      do {
        try dropAlias(alias)
        result.aliasesDropped += 1
      } catch {
        if result.errors.count < 8 {
          result.errors.append("alias of slot \(alias.slot): \(error)")
        }
      }
    }
    switch guestMapping {
    case .unmapped:
      break
    case .whole:
      let code = hv_vm_unmap(MachPageGeometry.dataGPA, MachPageGeometry.dataBytes)
      if code == HV_SUCCESS {
        result.guestUnmapped = guestMapped.filter { $0 }.count
        for slot in guestMapped.indices { guestMapped[slot] = false }
      } else {
        result.errors.append("unmap-data \(code)")
      }
    case .fragmented:
      for slot in guestMapped.indices where guestMapped[slot] {
        let code = hv_vm_unmap(guestAddress(of: slot), MachPageGeometry.pageSize)
        if code == HV_SUCCESS {
          guestMapped[slot] = false
          result.guestUnmapped += 1
        } else if result.errors.count < 8 {
          result.errors.append("unmap-slot \(slot) \(code)")
        }
      }
    }
    if !guestMapped.contains(true) { guestMapping = .unmapped }
    var releasable = [Bool](repeating: false, count: slots.count)
    for slot in slots.indices where slots[slot] != .released {
      if guestMapped[slot] {
        result.hostSkipped += 1
      } else if slots[slot] == .placeholder,
        let reason = placeholderRefusal(slot, entry: query(slot: slot))
      {
        // Not provably ours any more, so it is left in place and reported, never freed.
        result.hostSkipped += 1
        if result.errors.count < 8 { result.errors.append(reason) }
      } else {
        releasable[slot] = true
      }
    }
    var slot = 0
    while slot < slots.count {
      guard releasable[slot] else {
        slot += 1
        continue
      }
      var end = slot + 1
      while end < slots.count, releasable[end] { end += 1 }
      let code = MachPageKernel.deallocate(
        address(of: slot), bytes: (end - slot) * MachPageGeometry.pageSize)
      if code == KERN_SUCCESS {
        for index in slot..<end {
          if slots[index] == .placeholder { result.placeholdersDeallocated += 1 }
          slots[index] = .released
          placeholderStates[index] = nil
        }
        result.hostDeallocated += end - slot
      } else if result.errors.count < 8 {
        result.errors.append("deallocate \(slot)..<\(end) \(code)")
      }
      slot = end
    }
    released = result.errors.isEmpty && result.hostSkipped == 0 && aliases.isEmpty
    return result
  }

  private static func nativeSetting(_ name: String) throws -> Int32 {
    var value: Int32 = 0
    var count = MemoryLayout<Int32>.size
    guard sysctlbyname(name, &value, &count, nil, 0) == 0, count == MemoryLayout<Int32>.size else {
      throw Failure.observation
    }
    return value
  }

  /// Read-only bracket, as in the reviewed lab: this process's observation geometry must be
  /// native and the footprint override off. Nothing is ever set.
  private static func observationMode() throws -> (pageSize: Int32, footprint: Int32) {
    let size = try nativeSetting("vm.self_region_page_size")
    let footprint = try nativeSetting("vm.self_region_footprint")
    guard size == 1 || size == Int32(MachPageGeometry.pageSize), footprint == 0 else {
      throw Failure.geometry
    }
    return (size, footprint)
  }

  private static func query(
    _ location: UInt64, pages: Int, into total: inout MachPageDispositions
  ) throws {
    try withUnsafeTemporaryAllocation(of: integer_t.self, capacity: 256) { scratch in
      var done = 0
      while done < pages {
        let batch = min(pages - done, 255)
        scratch.initialize(repeating: .min)
        var count = UInt64(batch + 1)
        let code = mach_vm_page_range_query(
          mach_task_self_, location + UInt64(done * MachPageGeometry.pageSize),
          UInt64(batch * MachPageGeometry.pageSize),
          UInt64(UInt(bitPattern: scratch.baseAddress!)), &count)
        guard code == KERN_SUCCESS else { throw Failure.native("page-query", code) }
        // The reply count is entries, not bytes; an unwritten or short reply is not accepted.
        guard count == UInt64(batch) else { throw Failure.observation }
        for index in 0..<batch {
          let flags = scratch[index]
          guard flags != .min else { throw Failure.observation }
          total.pages += 1
          if flags & VM_PAGE_QUERY_PAGE_PRESENT != 0 { total.present += 1 }
          if flags & VM_PAGE_QUERY_PAGE_PAGED_OUT != 0 { total.pagedOut += 1 }
          if flags & VM_PAGE_QUERY_PAGE_REUSABLE != 0 { total.reusable += 1 }
          let strange =
            VM_PAGE_QUERY_PAGE_FICTITIOUS | VM_PAGE_QUERY_PAGE_COPIED | VM_PAGE_QUERY_PAGE_EXTERNAL
          if flags & strange != 0 { total.anomalous += 1 }
        }
        done += batch
      }
    }
  }

  /// Native page dispositions of every live object slot. Placeholders and released slots are not
  /// queried, so after retirement this still describes live pages only. Counters are recorded,
  /// not judged: compressed or paged-out pages are findings, not failures.
  func dispositions() throws -> MachPageDispositions {
    let before = try Self.observationMode()
    var total = MachPageDispositions()
    var slot = 0
    while slot < slots.count {
      if slots[slot] != .owned {
        slot += 1
        continue
      }
      var end = slot + 1
      while end < slots.count, slots[end] == .owned { end += 1 }
      try Self.query(address(of: slot), pages: end - slot, into: &total)
      slot = end
    }
    let after = try Self.observationMode()
    guard after == before else { throw Failure.geometry }
    return total
  }
}
