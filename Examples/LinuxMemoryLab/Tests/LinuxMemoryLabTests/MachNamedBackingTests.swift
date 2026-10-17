import Darwin
import Testing

@testable import NativeLinuxVMM

// Real Mach named-object boundary, no hypervisor. Each check compares the owner with an
// independent kernel view (map walk, mincore, raw words) so a faked count or a missing guard
// fails visibly. Hardware qualification remains separate from these hosted kernel-boundary tests.
private enum NamedFixture {
  enum Native: Error { case native(String, Int32) }
  static let block = 2 << 20
  static let page = 16384
  static let pages = UInt64(block / page)
  static var zero: MachNamedBacking.Counts { .init(resident: 0, dirty: 0, swapped: 0) }

  static func address(_ pointer: UnsafeMutableRawPointer) -> UInt64 {
    UInt64(UInt(bitPattern: pointer))
  }

  /// Independent map walk of the whole mapping; shares no code with the owner.
  static func region(_ original: UInt64) throws -> vm_region_submap_info_data_64_t {
    var start = original
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
    guard status == KERN_SUCCESS, start == original, size == UInt64(block) else {
      throw Native.native("region", status)
    }
    return info
  }

  /// mincore never faults pages in; it is the independent residency view per native page.
  static func residentFlags(_ pointer: UnsafeMutableRawPointer) throws -> Int {
    try withUnsafeTemporaryAllocation(of: Int8.self, capacity: block / page) { flags in
      flags.initialize(repeating: 0)
      guard mincore(pointer, block, flags.baseAddress!) == 0 else {
        throw Native.native("mincore", errno)
      }
      return flags.reduce(0) { $0 + ($1 & 1 != 0 ? 1 : 0) }
    }
  }

  static func pattern(_ offset: Int, _ salt: UInt64) -> UInt64 {
    ((UInt64(offset) &* 0x9E37_79B9_7F4A_7C15) ^ salt) | 1
  }

  static func fill(_ pointer: UnsafeMutableRawPointer, salt: UInt64) {
    for offset in stride(from: 0, to: block, by: 8) {
      pointer.storeBytes(of: pattern(offset, salt), toByteOffset: offset, as: UInt64.self)
    }
  }

  static func mismatches(_ pointer: UnsafeMutableRawPointer, salt: UInt64) -> Int {
    var count = 0
    for offset in stride(from: 0, to: block, by: 8)
    where pointer.load(fromByteOffset: offset, as: UInt64.self) != pattern(offset, salt) {
      count += 1
    }
    return count
  }

  static func nonzeroWords(_ pointer: UnsafeMutableRawPointer) -> Int {
    var count = 0
    for offset in stride(from: 0, to: block, by: 8)
    where pointer.load(fromByteOffset: offset, as: UInt64.self) != 0 {
      count += 1
    }
    return count
  }

  /// The deliberate second object reference, created exactly like MemoryDevice's diagnostic alias.
  static func makeAlias(of pointer: UnsafeMutableRawPointer) throws -> UInt64 {
    var target: UInt64 = 0
    var current: vm_prot_t = 0
    var maximum: vm_prot_t = 0
    let status = mach_vm_remap(
      mach_task_self_, &target, UInt64(block), 0, VM_FLAGS_ANYWHERE, mach_task_self_,
      address(pointer), 0, &current, &maximum, VM_INHERIT_NONE)
    guard status == KERN_SUCCESS else { throw Native.native("alias", status) }
    return target
  }

  static func dropAlias(_ alias: UInt64) throws {
    let status = mach_vm_deallocate(mach_task_self_, alias, UInt64(block))
    guard status == KERN_SUCCESS else { throw Native.native("drop-alias", status) }
  }

  static func cleanupAlias(_ alias: UInt64) {
    do { try dropAlias(alias) } catch {
      Issue.record("Owned fixture alias cleanup failed: \(error)")
    }
  }

  static func isAbsent(_ original: UInt64) throws -> Bool {
    var start = original
    var size: UInt64 = 0
    var info = vm_region_basic_info_data_64_t()
    var count = mach_msg_type_number_t(MemoryLayout<vm_region_basic_info_data_64_t>.size / 4)
    var port: mach_port_t = 0
    let status = withUnsafeMutablePointer(to: &info) { value in
      value.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        mach_vm_region(mach_task_self_, &start, &size, VM_REGION_BASIC_INFO_64, $0, &count, &port)
      }
    }
    if port != 0 {
      let released = mach_port_deallocate(mach_task_self_, port)
      guard released == KERN_SUCCESS else { throw Native.native("region-port-release", released) }
    }
    return status == KERN_INVALID_ADDRESS
      || status == KERN_SUCCESS && start >= original + UInt64(block)
  }

  static func refusalDetail(_ body: () throws -> Void) -> String? {
    do { try body() } catch let refusal as MachNamedBacking.Refusal {
      return refusal.detail
    } catch { return "unexpected \(error)" }
    return nil
  }

  static func close(_ backing: MachNamedBacking) {
    do { try backing.close() } catch {
      Issue.record("Named backing close failed: \(error)", severity: .error)
    }
  }

  /// Kernel entry teardown is observed, not assumed synchronous; the end state is still exact.
  static func eventually(_ condition: () throws -> Bool) rethrows -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while ContinuousClock.now < deadline {
      if try condition() { return true }
      usleep(1000)
    }
    return try condition()
  }
}

@Test func namedBackingStartsAsAnExclusiveColdWholeObjectWithNonfaultingDirectCounts() throws {
  let backing = try MachNamedBacking.create()
  defer { NamedFixture.close(backing) }
  let pointer = try #require(backing.pointer)
  let address = NamedFixture.address(pointer)
  #expect(address % UInt64(NamedFixture.page) == 0)
  let info = try NamedFixture.region(address)
  let readWrite = VM_PROT_READ | VM_PROT_WRITE
  #expect(info.offset == 0 && info.is_submap == 0 && info.shadow_depth == 0)
  #expect(info.external_pager == 0 && info.pages_wired == 0 && info.user_wired_count == 0)
  #expect(info.protection == readWrite && info.max_protection == readWrite)
  #expect(info.inheritance == VM_INHERIT_NONE)
  #expect(info.user_tag == UInt32(VM_MEMORY_APPLICATION_SPECIFIC_1))
  // The owned entry plus the one owner mapping; hardware must confirm this exact count.
  #expect(info.ref_count == 2)
  let inspection = try backing.inspect()
  #expect(inspection.size == UInt64(NamedFixture.block) && inspection.offset == 0)
  #expect(inspection.references == 2 && inspection.objectID != 0)
  #expect(inspection.counts == NamedFixture.zero)
  // Counting is nonfaulting: repeated direct queries and mincore still see a cold object.
  #expect(try backing.counts() == NamedFixture.zero)
  #expect(try NamedFixture.residentFlags(pointer) == 0)
}

@Test func touchedPagesAreCountedExactlyAndPurgeIsColdBeforeAnyHostRead() throws {
  let backing = try MachNamedBacking.create()
  defer { NamedFixture.close(backing) }
  let pointer = try #require(backing.pointer)
  for page in 0..<4 {
    pointer.storeBytes(of: UInt8(1), toByteOffset: page * NamedFixture.page, as: UInt8.self)
  }
  let touched = try backing.counts()
  #expect(touched.resident == 4 && touched.swapped == 0 && touched.dirty <= touched.resident)
  #expect(try NamedFixture.residentFlags(pointer) == 4)
  for cycle in 0..<3 {
    let salt = UInt64(cycle + 1) << 32
    NamedFixture.fill(pointer, salt: salt)
    #expect(try backing.counts().resident == NamedFixture.pages)
    let discard = try backing.discard()
    #expect(discard.before.counts.resident == NamedFixture.pages)
    #expect(discard.before.references == 2 && discard.after == NamedFixture.zero)
    // Cold before any host read: the direct counts and mincore agree, repeatedly.
    #expect(try backing.counts() == NamedFixture.zero)
    #expect(try NamedFixture.residentFlags(pointer) == 0)
    // Regrowth is zero-filled; only now does a host read fault pages in.
    #expect(NamedFixture.nonzeroWords(pointer) == 0)
    NamedFixture.fill(pointer, salt: ~salt)
    #expect(NamedFixture.mismatches(pointer, salt: ~salt) == 0)
  }
}

@Test func aliasRefusesBeforeAnyContentIsDestroyedAndDiscardsAfterTheDrop() throws {
  let backing = try MachNamedBacking.create()
  defer { NamedFixture.close(backing) }
  let pointer = try #require(backing.pointer)
  NamedFixture.fill(pointer, salt: 0x51)
  let alias = try NamedFixture.makeAlias(of: pointer)
  var aliasLive = true
  defer {
    if aliasLive { NamedFixture.cleanupAlias(alias) }
  }
  let aliasPointer = try #require(UnsafeMutableRawPointer(bitPattern: UInt(alias)))
  #expect(try NamedFixture.region(NamedFixture.address(pointer)).ref_count == 3)
  let detail = NamedFixture.refusalDetail { _ = try backing.discard() }
  #expect(detail?.contains("refs=3") == true)
  // Zero bytes were destroyed: raw words through both mappings and the object counts agree.
  #expect(NamedFixture.mismatches(pointer, salt: 0x51) == 0)
  #expect(NamedFixture.mismatches(aliasPointer, salt: 0x51) == 0)
  #expect(try backing.counts().resident == NamedFixture.pages)
  #expect(try NamedFixture.residentFlags(pointer) == Int(NamedFixture.pages))
  try NamedFixture.dropAlias(alias)
  aliasLive = false
  let discard = try backing.discard()
  #expect(discard.before.references == 2 && discard.after == NamedFixture.zero)
}

@Test func aliasAppearingAfterInspectionStillRefusesBecauseDestructionRechecks() throws {
  let backing = try MachNamedBacking.create()
  defer { NamedFixture.close(backing) }
  let pointer = try #require(backing.pointer)
  NamedFixture.fill(pointer, salt: 0x77)
  // The earlier plan looked exclusive; it must not authorize a later destruction.
  let planned = try backing.inspect()
  #expect(planned.references == 2 && planned.counts.resident == NamedFixture.pages)
  let alias = try NamedFixture.makeAlias(of: pointer)
  var aliasLive = true
  defer {
    if aliasLive { NamedFixture.cleanupAlias(alias) }
  }
  let detail = NamedFixture.refusalDetail { _ = try backing.discard() }
  #expect(detail?.contains("refs=3") == true)
  #expect(NamedFixture.mismatches(pointer, salt: 0x77) == 0)
  #expect(try backing.counts().resident == NamedFixture.pages)
  try NamedFixture.dropAlias(alias)
  aliasLive = false
  #expect(try backing.discard().before.references == 2)
}

@Test func wiringAndHostProtectionDriftAreRefusedAndMaximumProtectionExcludesExecute() throws {
  let backing = try MachNamedBacking.create()
  defer { NamedFixture.close(backing) }
  let pointer = try #require(backing.pointer)
  let address = NamedFixture.address(pointer)
  let size = UInt64(NamedFixture.block)
  NamedFixture.fill(pointer, salt: 0x33)
  // The owner mapping is NX with a read/write maximum: the kernel refuses to make it executable.
  let execute = mach_vm_protect(
    mach_task_self_, address, size, 0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE)
  #expect(execute != KERN_SUCCESS)
  #expect(try NamedFixture.region(address).max_protection == (VM_PROT_READ | VM_PROT_WRITE))
  // Host protection drift is an ownership change, never something to destroy through.
  try #require(mach_vm_protect(mach_task_self_, address, size, 0, VM_PROT_READ) == KERN_SUCCESS)
  #expect(NamedFixture.refusalDetail { _ = try backing.discard() } != nil)
  try #require(
    mach_vm_protect(mach_task_self_, address, size, 0, VM_PROT_READ | VM_PROT_WRITE)
      == KERN_SUCCESS)
  // A wired mapping may not be emptied underneath its wiring.
  try #require(mlock(pointer, NamedFixture.block) == 0, "mlock failed with errno \(errno)")
  #expect(NamedFixture.refusalDetail { _ = try backing.discard() } != nil)
  #expect(NamedFixture.mismatches(pointer, salt: 0x33) == 0)
  try #require(munlock(pointer, NamedFixture.block) == 0, "munlock failed with errno \(errno)")
  #expect(try backing.discard().after == NamedFixture.zero)
}

private final class ForeignAttempt: @unchecked Sendable {
  let backing: MachNamedBacking
  // Written only by the native worker, read only after its actual pthread_join.
  var failures: [MachNamedBacking.Failure?] = []
  var pointerRefused = false
  init(_ backing: MachNamedBacking) { self.backing = backing }
}

// Synchronous native-thread fixture runs only in a fresh exit-test child.
private func verifyForeignThreadConfinement() throws {
  let backing = try MachNamedBacking.create()
  defer { NamedFixture.close(backing) }
  let pointer = try #require(backing.pointer)
  let address = NamedFixture.address(pointer)
  NamedFixture.fill(pointer, salt: 0x99)
  let attempt = ForeignAttempt(backing)
  var worker: pthread_t?
  let context = Unmanaged.passRetained(attempt).toOpaque()
  let created = pthread_create(&worker, nil, { context in
    let attempt = Unmanaged<ForeignAttempt>.fromOpaque(context).takeRetainedValue()
    do { _ = try attempt.backing.inspect() } catch {
      attempt.failures.append(error as? MachNamedBacking.Failure)
    }
    do { _ = try attempt.backing.discard() } catch {
      attempt.failures.append(error as? MachNamedBacking.Failure)
    }
    do { try attempt.backing.close() } catch {
      attempt.failures.append(error as? MachNamedBacking.Failure)
    }
    attempt.pointerRefused = attempt.backing.pointer == nil
    return nil
  }, context)
  if created != 0 { Unmanaged<ForeignAttempt>.fromOpaque(context).release() }
  try #require(created == 0)
  let joined = pthread_join(try #require(worker), nil)
  try #require(joined == 0)
  #expect(attempt.pointerRefused)
  #expect(attempt.failures == [.confinement, .confinement, .confinement])
  #expect(NamedFixture.mismatches(pointer, salt: 0x99) == 0)
  #expect(try backing.counts().resident == NamedFixture.pages)
  #expect(try NamedFixture.region(address).ref_count == 2)
}

@Test(.timeLimit(.minutes(1))) func foreignThreadsCannotInspectDiscardOrCloseAndNothingIsDestroyed() async {
  await #expect(processExitsWith: .success) {
    try verifyForeignThreadConfinement()
  }
}

@Test(.timeLimit(.minutes(1))) func closeReleasesTheEntryReferenceAndTheOwnedMappingExactlyOnce() async {
  await #expect(processExitsWith: .success) {
    let backing = try MachNamedBacking.create()
    let pointer = try #require(backing.pointer)
    let address = NamedFixture.address(pointer)
    NamedFixture.fill(pointer, salt: 0x44)
    let alias = try NamedFixture.makeAlias(of: pointer)
    defer { NamedFixture.cleanupAlias(alias) }
    let aliasPointer = try #require(UnsafeMutableRawPointer(bitPattern: UInt(alias)))
    #expect(try NamedFixture.region(alias).ref_count == 3)
    try backing.close()
    #expect(backing.pointer == nil)
    #expect(try NamedFixture.isAbsent(address))
    // The alias now holds the only object reference: close released the entry send right too.
    #expect(try NamedFixture.eventually { try NamedFixture.region(alias).ref_count == 1 })
    #expect(NamedFixture.mismatches(aliasPointer, salt: 0x44) == 0)
    try backing.close()
    #expect(throws: MachNamedBacking.Failure.self) { _ = try backing.inspect() }
    #expect(throws: MachNamedBacking.Failure.self) { _ = try backing.counts() }
    #expect(throws: MachNamedBacking.Failure.self) { try backing.attachMapping() }
  }
}

@Test(.timeLimit(.minutes(1))) func droppingAnOwnerNeverReleasesItsMappingOrEntry() async {
  await #expect(processExitsWith: .success) {
    var abandoned: UInt64 = 0
    var alias: UInt64 = 0
    weak var owner: MachNamedBacking?
    do {
      let backing = try MachNamedBacking.create()
      owner = backing
      let pointer = try #require(backing.pointer)
      abandoned = NamedFixture.address(pointer)
      // Purged first, so the one send right deliberately abandoned below pins no resident pages.
      _ = try backing.discard()
      alias = try NamedFixture.makeAlias(of: pointer)
    }
    defer {
      NamedFixture.cleanupAlias(alias)
      NamedFixture.cleanupAlias(abandoned)
    }
    #expect(owner == nil)
    // Mapping, retained entry and alias all survive deinit; only an explicit close releases them.
    #expect(try NamedFixture.region(abandoned).ref_count == 3)
    #expect(try !NamedFixture.isAbsent(abandoned))
  }
}

@Test(.timeLimit(.minutes(1))) func detachedObjectStaysOwnedColdAndReattachesWithItsOriginalIdentity() async {
  await #expect(processExitsWith: .success) {
    let backing = try MachNamedBacking.create()
    defer { NamedFixture.close(backing) }
    let pointer = try #require(backing.pointer)
    let address = NamedFixture.address(pointer)
    NamedFixture.fill(pointer, salt: 0xab)
    let identity = try backing.inspect().objectID
    _ = try backing.discard()
    try backing.detachMapping()
    #expect(try backing.pointer == nil && NamedFixture.isAbsent(address))
    #expect(throws: MachNamedBacking.Failure.self) { _ = try backing.inspect() }
    #expect(throws: MachNamedBacking.Failure.self) { try backing.detachMapping() }
    // The retained entry still reports its cold object with no mapping at all.
    #expect(try backing.counts() == NamedFixture.zero)
    try backing.attachMapping()
    #expect(throws: MachNamedBacking.Failure.self) { try backing.attachMapping() }
    let remapped = try #require(backing.pointer)
    let again = try backing.inspect()
    #expect(again.objectID == identity && again.references == 2)
    #expect(again.counts == NamedFixture.zero)
    #expect(try NamedFixture.residentFlags(remapped) == 0)
    #expect(NamedFixture.nonzeroWords(remapped) == 0)
  }
}

@Test func pageCountArithmeticIsCheckedAndUsesTheNativeSixteenKiBUnit() throws {
  #expect(MachNamedBacking.pageBytes == 16384)
  #expect(UInt64(sysconf(Int32(_SC_PAGESIZE))) == MachNamedBacking.pageBytes)
  #expect(MachNamedBacking.bytes == UInt64(MemoryDevice.block))
  let full = MachNamedBacking.Counts(resident: NamedFixture.pages, dirty: 3, swapped: 0)
  #expect(try full.residentBytes() == UInt64(MemoryDevice.block))
  let impossible = MachNamedBacking.Counts(resident: UInt64.max / 2, dirty: 0, swapped: 0)
  #expect(throws: MachNamedBacking.Failure.self) { _ = try impossible.residentBytes() }
}

@Test(.timeLimit(.minutes(1))) func replacedMappingIsNeverRestoredOrFreedByTheOldOwner() async {
  await #expect(processExitsWith: .success) {
    let oldOwner = try MachNamedBacking.create()
    let oldPointer = try #require(oldOwner.pointer)
    let oldAddress = NamedFixture.address(oldPointer)
    // The deliberately abandoned entry below retains no resident pages in this fresh child.
    _ = try oldOwner.discard()
    let foreignOwner = try MachNamedBacking.create()
    defer { NamedFixture.close(foreignOwner) }
    let foreignPointer = try #require(foreignOwner.pointer)
    NamedFixture.fill(foreignPointer, salt: 0xfeed)
    let foreignIdentity = try foreignOwner.inspect().objectID
    var target = oldAddress
    var current: vm_prot_t = 0
    var maximum: vm_prot_t = 0
    try #require(
      mach_vm_remap(
        mach_task_self_, &target, UInt64(NamedFixture.block), 0,
        VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self_,
        NamedFixture.address(foreignPointer), 0, &current, &maximum, VM_INHERIT_NONE)
        == KERN_SUCCESS)
    defer {
      do {
        if try !NamedFixture.isAbsent(oldAddress) { try NamedFixture.dropAlias(oldAddress) }
      } catch { Issue.record("Foreign fixture mapping cleanup failed: \(error)") }
    }
    #expect(target == oldAddress)
    #expect(try NamedFixture.region(oldAddress).object_id_full == foreignIdentity)
    #expect(throws: MachNamedBacking.Failure.self) { _ = try oldOwner.inspect() }
    #expect(oldOwner.pointer == nil)
    #expect(throws: MachNamedBacking.Failure.self) { try oldOwner.close() }
    // Require the independent map proof before dereferencing; the unfixed close removes it.
    try #require(try !NamedFixture.isAbsent(oldAddress))
    #expect(NamedFixture.mismatches(oldPointer, salt: 0xfeed) == 0)
    #expect(NamedFixture.mismatches(foreignPointer, salt: 0xfeed) == 0)
    #expect(try foreignOwner.counts().resident == NamedFixture.pages)
  }
}

@Test(.timeLimit(.minutes(1))) func externallyEmptiedContentsPoisonTheOwnerInsteadOfReportingBusy() async {
  await #expect(processExitsWith: .success) {
    for retainAlias in [false, true] {
      let backing = try MachNamedBacking.create()
      defer { NamedFixture.close(backing) }
      let pointer = try #require(backing.pointer)
      NamedFixture.fill(pointer, salt: 0xca11)
      let alias = retainAlias ? try NamedFixture.makeAlias(of: pointer) : nil
      defer {
        if let alias {
          do { try NamedFixture.dropAlias(alias) } catch {
            Issue.record("State fixture alias cleanup failed: \(error)")
          }
        }
      }
      var size = UInt64(NamedFixture.block)
      var entry: mach_port_t = 0
      try #require(
        mach_make_memory_entry_64(
          mach_task_self_, &size, NamedFixture.address(pointer),
          VM_PROT_READ | VM_PROT_WRITE, &entry, 0) == KERN_SUCCESS)
      try #require(entry != 0 && size == UInt64(NamedFixture.block))
      var state = VM_PURGABLE_EMPTY
      let emptied = mach_memory_entry_purgable_control(entry, VM_PURGABLE_SET_STATE, &state)
      let released = mach_port_deallocate(mach_task_self_, entry)
      try #require(emptied == KERN_SUCCESS && released == KERN_SUCCESS)
      // The second entry is gone; the old object really lost its contents before inspection.
      try #require(try backing.counts() == NamedFixture.zero)
      #expect(throws: MachNamedBacking.Failure.self) { _ = try backing.inspect() }
      #expect(backing.pointer == nil)
      #expect(throws: MachNamedBacking.Failure.self) { _ = try backing.discard() }
      // Identity is still known, so explicit shutdown may release the poisoned native resources.
      try backing.close()
      #expect(try NamedFixture.isAbsent(NamedFixture.address(pointer)))
    }
  }
}

// MemoryDevice-level checks need no hypervisor when the extent state is installed directly and
// the guard under test fires before any stage-2 call.
private func installedExtent(
  _ device: MemoryDevice
) throws -> (MachNamedBacking, UnsafeMutableRawPointer) {
  let extent = device.extents[0]
  let backing = try MachNamedBacking.create()
  extent.backing = backing
  extent.plugged = true
  extent.mapped = true
  let pointer = try #require(backing.pointer)
  return (backing, pointer)
}

private func releaseInstalled(_ device: MemoryDevice) {
  let extent = device.extents[0]
  extent.mapped = false
  extent.plugged = false
  do { try device.close() } catch {
    Issue.record("Device close failed: \(error)", severity: .error)
  }
}

@Test func pinnedExtentRefusalIsAbsoluteAndDestroysNothing() throws {
  let device = MemoryDevice(held: false)
  let (backing, pointer) = try installedExtent(device)
  defer { releaseInstalled(device) }
  device.extents[0].metadataPinned = true
  NamedFixture.fill(pointer, salt: 0x12)
  #expect(try device.recycleOwned([0], quiescence: (true, 1, 1)) == false)
  #expect(device.refusals.last?["reason"] as? String == "metadata-pinned")
  #expect(device.refusalsTotal == 1 && device.recycledBackingBytes == 0)
  #expect(device.recyclingObservationsTotal == 0 && device.extents[0].mapped)
  #expect(NamedFixture.mismatches(pointer, salt: 0x12) == 0)
  #expect(try backing.counts().resident == NamedFixture.pages)
}

@Test func heldControlRefusesRecyclingBeforeAnyDiscard() throws {
  let device = MemoryDevice(held: true)
  let (backing, pointer) = try installedExtent(device)
  defer { releaseInstalled(device) }
  NamedFixture.fill(pointer, salt: 0x21)
  #expect(throws: DeviceFailure.self) {
    _ = try device.recycleOwned([0], quiescence: (true, 1, 1))
  }
  #expect(device.recyclingObservationsTotal == 0 && device.extents[0].mapped)
  #expect(NamedFixture.mismatches(pointer, salt: 0x21) == 0)
  #expect(try backing.counts().resident == NamedFixture.pages)
}

@Test(.timeLimit(.minutes(1))) func failedCloseRetainsEveryNativeResourceUntilTheAliasDropIsConfirmed() async {
  await #expect(processExitsWith: .success) {
    let device = MemoryDevice(held: false)
    let extent = device.extents[0]
    let backing = try MachNamedBacking.create()
    extent.backing = backing
    let pointer = try #require(backing.pointer)
    let address = NamedFixture.address(pointer)
    NamedFixture.fill(pointer, salt: 0x66)
    // A range whose end wraps makes the native deallocation fail without any side effect.
    device.aliasAddress = UInt64.max
    #expect(throws: DeviceFailure.self) { try device.close() }
    #expect(device.aliasAddress == UInt64.max)
    #expect(extent.backing != nil && backing.pointer == pointer)
    #expect(NamedFixture.mismatches(pointer, salt: 0x66) == 0)
    // Once the drop is confirmed the explicit close releases the mapping and the retained entry.
    device.aliasAddress = nil
    try device.close()
    #expect(extent.backing == nil && backing.pointer == nil)
    #expect(try NamedFixture.isAbsent(address))
    try device.close()
  }
}
