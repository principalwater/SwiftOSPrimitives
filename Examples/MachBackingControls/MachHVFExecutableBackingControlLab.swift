import Darwin
import Foundation
import Hypervisor

private enum Failure: Error {
  case native(String, Int32)
  case invariant(String)
}

private struct Counts {
  var resident: UInt64 = 0
  var dirty: UInt64 = 0
  var swapped: UInt64 = 0
  var record: [String: UInt64] {
    ["residentPages": resident, "dirtyPages": dirty, "swappedPages": swapped]
  }
}

private struct TaskMemory {
  let resident: UInt64
  let footprint: UInt64
  static func capture() throws -> Self {
    var info = task_vm_info_data_t()
    let capacity = MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
    var count = mach_msg_type_number_t(capacity)
    let code = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard code == KERN_SUCCESS else { throw Failure.native("task-info", code) }
    return Self(resident: info.resident_size, footprint: info.phys_footprint)
  }
  var record: [String: UInt64] { ["residentBytes": resident, "footprintBytes": footprint] }
}

/// Owns one fixed synthetic 64MiB object and one synchronous vCPU; no disk or network.
private final class Fixture {
  static let bytes = 64 << 20
  static let page = 16384
  static let slots = bytes / page
  private let deadline = ContinuousClock.now.advanced(by: .seconds(15))
  private var entry: mach_port_t = 0
  private var base: UInt64?
  private var scratch: UInt64?
  private var vmCreated = false
  private var cpu: hv_vcpu_t?
  private var exitInfo: UnsafeMutablePointer<hv_vcpu_exit_t>?
  private var codePointer: UnsafeMutableRawPointer?
  private var codeMapped = false
  private var dataMapped = false
  private var guestRuns = 0
  private var guestExecutedData = false
  private let ownerThread = pthread_self()
  private static let codeGPA: UInt64 = 0x10_0000
  private static let dataGPA: UInt64 = 0x4000_0000
  private static let sentinel: UInt64 = 0xa5a5_0000_0000_0001
  private(set) var records: [[String: Any]] = []

  private func check(_ code: kern_return_t, _ operation: String) throws {
    guard code == KERN_SUCCESS else { throw Failure.native(operation, code) }
  }
  private func require(_ value: Bool, _ detail: String) throws {
    guard value else { throw Failure.invariant(detail) }
  }
  private func time() throws {
    try require(ContinuousClock.now < deadline, "original 15s deadline expired")
    try require(pthread_equal(ownerThread, pthread_self()) != 0, "native owner thread changed")
  }
  private func setupHVF() throws {
    try check(hv_vm_create(nil), "hv-create")
    vmCreated = true
    try check(hv_vm_allocate(&codePointer, Self.page, 0), "hv-code-allocate")
    guard let codePointer else { throw Failure.invariant("code pointer") }
    codePointer.storeBytes(of: UInt32(0xf940_0022), as: UInt32.self)
    codePointer.storeBytes(of: UInt32(0xd400_0002), toByteOffset: 4, as: UInt32.self)
    sys_icache_invalidate(codePointer, Self.page)
    try check(hv_vm_map(codePointer, Self.codeGPA, Self.page,
                      UInt64(HV_MEMORY_READ | HV_MEMORY_EXEC)), "hv-code-map")
    codeMapped = true
    try check(mach_vm_protect(mach_task_self_, UInt64(UInt(bitPattern: codePointer)),
                              UInt64(Self.page), 0, VM_PROT_READ), "code-host-readonly")
    var identifier: hv_vcpu_t = 0
    try check(hv_vcpu_create(&identifier, &exitInfo, nil), "hv-cpu-create")
    cpu = identifier
    try check(hv_vcpu_set_vtimer_mask(identifier, true), "hv-mask-vtimer")
    try mapDataHVF()
  }
  private func mapDataHVF() throws {
    try require(vmCreated && cpu != nil && !dataMapped, "data map order")
    try check(hv_vm_map(UnsafeMutableRawPointer(try pointer()), Self.dataGPA, Self.bytes,
                       UInt64(HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC)), "hv-data-map")
    dataMapped = true
  }
  private func unmapDataHVF() throws {
    try require(dataMapped, "data unmap order")
    try check(hv_vm_unmap(Self.dataGPA, Self.bytes), "hv-data-unmap")
    dataMapped = false
  }
  private func guestRead(_ offset: Int, expected: UInt64?, entry: UInt64 = Fixture.codeGPA) throws {
    guard let cpu, let exitInfo, let codePointer else {
      throw Failure.invariant("guest unavailable")
    }
    try require(codePointer.load(as: UInt32.self) == 0xf940_0022
                && codePointer.load(fromByteOffset: 4, as: UInt32.self) == 0xd400_0002,
                "code changed")
    let address = Self.dataGPA + UInt64(offset)
    for (register, value) in [(HV_REG_PC, entry), (HV_REG_CPSR, UInt64(0x3c5)),
                              (HV_REG_X0, UInt64(0x41)), (HV_REG_X1, address),
                              (HV_REG_X2, Self.sentinel)] {
      try check(hv_vcpu_set_reg(cpu, register, value), "hv-set-register")
    }
    try check(hv_vcpu_run(cpu), "hv-run")
    guestRuns += 1
    var pc: UInt64 = 0
    var payload: UInt64 = 0
    try check(hv_vcpu_get_reg(cpu, HV_REG_PC, &pc), "hv-pc")
    try check(hv_vcpu_get_reg(cpu, HV_REG_X2, &payload), "hv-payload")
    let event = exitInfo.pointee
    try require(event.reason == HV_EXIT_REASON_EXCEPTION, "unexpected guest exit")
    let syndrome = event.exception.syndrome
    if let expected {
      try require(dataMapped && syndrome >> 26 == 0x16 && syndrome & 0xffff == 0
                    && pc == entry + 8 && payload == expected, "guest data mismatch")
    } else {
      try require(!dataMapped && syndrome >> 26 == 0x24 && syndrome & 0x3c == 0x04
                    && syndrome & 0x40 == 0 && pc == Self.codeGPA && payload == Self.sentinel
                    && event.exception.physical_address >> 12 == address >> 12,
                  "missing exact stage2 translation fault")
    }
  }
  private func guestVerify(_ zero: Bool) throws {
    for slot in 0..<Self.slots {
      if slot & 127 == 0 { try time() }
      let offset = slot * Self.page
      try guestRead(offset, expected: zero ? 0 : word(offset / 8))
      try guestRead(offset + Self.page - 8,
                    expected: zero ? 0 : word((offset + Self.page - 8) / 8))
    }
  }
  private func executeFromOwnedData() throws {
    let pointer = UnsafeMutableRawPointer(try pointer())
    var start = UInt64(UInt(bitPattern: pointer))
    var size: UInt64 = 0
    var depth: UInt32 = 0
    var info = vm_region_submap_info_data_64_t()
    let words = MemoryLayout<vm_region_submap_info_data_64_t>.size / 4
    var count = mach_msg_type_number_t(words)
    let status = withUnsafeMutablePointer(to: &info) { value in
      value.withMemoryRebound(to: integer_t.self, capacity: words) {
        mach_vm_region_recurse(mach_task_self_, &start, &size, &depth, $0, &count)
      }
    }
    try check(status, "data-region")
    let readWrite = VM_PROT_READ | VM_PROT_WRITE
    try require(info.protection == readWrite && info.max_protection == readWrite,
                "host data must remain RW/NX")
    // Guest execution permission is independent of the host's NX mapping.
    pointer.storeBytes(of: UInt32(0xf940_0022), as: UInt32.self)
    pointer.storeBytes(of: UInt32(0xd400_0002), toByteOffset: 4, as: UInt32.self)
    sys_icache_invalidate(pointer, 8)
    try guestRead(Self.page, expected: word(Self.page / 8), entry: Self.dataGPA)
    pointer.storeBytes(of: word(0), as: UInt64.self)
    sys_icache_invalidate(pointer, 8)
    try verifyAllCanaries()
    guestExecutedData = true
  }
  private func pointer() throws -> UnsafeMutablePointer<UInt64> {
    guard let base, let pointer = UnsafeMutablePointer<UInt64>(bitPattern: UInt(base)) else {
      throw Failure.invariant("mapping not owned")
    }
    return pointer
  }
  private func counts() throws -> Counts {
    var result = Counts()
    try check(
      mach_memory_entry_get_page_counts(entry, &result.resident, &result.dirty, &result.swapped),
      "entry-page-counts")
    return result
  }
  private func state() throws -> Int32 {
    var state: Int32 = -1
    try check(mach_memory_entry_purgable_control(entry, VM_PURGABLE_GET_STATE, &state), "get-state")
    return state & VM_PURGABLE_STATE_MASK
  }
  private func setState(_ desired: Int32) throws {
    var previous = desired
    // This is per-entry SET_STATE only. Never call global PURGE_ALL.
    try check(
      mach_memory_entry_purgable_control(entry, VM_PURGABLE_SET_STATE, &previous), "set-state")
    try require(try state() == desired, "requested object state was not observed")
  }
  private func word(_ index: Int) -> UInt64 {
    var value = UInt64(index) &+ 0x9e37_79b9_7f4a_7c15
    value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
    value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
    return value ^ (value >> 31)
  }
  private func fill() throws {
    let pointer = try pointer()
    for slot in 0..<Self.slots {
      if slot & 127 == 0 { try time() }
      for index in 0..<(Self.page / 8) {
        let offset = slot * (Self.page / 8) + index
        pointer[offset] = word(offset)
      }
    }
  }
  private func verifyZero() throws {
    let pointer = try pointer()
    for slot in 0..<Self.slots {
      if slot & 127 == 0 { try time() }
      for index in 0..<(Self.page / 8) {
        try require(pointer[slot * (Self.page / 8) + index] == 0, "discarded data not zero")
      }
    }
  }
  private func verifyCanary(_ pointer: UnsafePointer<UInt64>, slot: Int) throws {
    for index in 0..<(Self.page / 8) {
      try require(pointer[index] == word(slot * (Self.page / 8) + index), "canary mismatch")
    }
  }
  private func verifyAllCanaries() throws {
    let pointer = try pointer()
    for slot in 0..<Self.slots {
      if slot & 127 == 0 { try time() }
      try verifyCanary(UnsafePointer(pointer.advanced(by: slot * (Self.page / 8))), slot: slot)
    }
  }
  private func pressure() throws -> Int32 {
    var level: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
      throw Failure.native("pressure", errno)
    }
    try require(size == MemoryLayout<Int32>.size && level == 1, "host pressure is not normal")
    return level
  }

  func run(_ profile: String) throws {
    try time()
    _ = try pressure()
    try require(sysconf(Int32(_SC_PAGESIZE)) == Self.page, "16KiB host required")
    var size: memory_object_size_t = memory_object_size_t(Self.bytes)
    let purgable = profile == "purgable-hvf"
    try require(purgable, "fixed HVF profile required")
    let permission = MAP_MEM_NAMED_CREATE | VM_PROT_READ | VM_PROT_WRITE
      | (purgable ? MAP_MEM_PURGABLE : 0)
    try check(mach_make_memory_entry_64(mach_task_self_, &size, 0, permission, &entry, 0), "create")
    try require(entry != 0 && size == Self.bytes, "named object shape")
    var address: mach_vm_address_t = 0
    try check(
      mach_vm_map(
        mach_task_self_, &address, UInt64(Self.bytes), 0, VM_FLAGS_ANYWHERE, entry, 0, 0,
        VM_PROT_READ | VM_PROT_WRITE, VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_NONE), "map")
    base = address
    let cold = try counts()
    try require(cold.resident == 0 && cold.swapped == 0, "new object is not cold")
    if purgable { try setState(VM_PURGABLE_NONVOLATILE) }
    try fill()
    let touched = try counts()
    try require(touched.resident == Self.slots && touched.swapped == 0, "first touch not resident")
    try verifyAllCanaries()
    try setupHVF()
    try executeFromOwnedData()
    try guestVerify(false)
    let before = try TaskMemory.capture()
    if profile == "ordinary-reject" {
      var requested = VM_PURGABLE_EMPTY
      let code = mach_memory_entry_purgable_control(entry, VM_PURGABLE_SET_STATE, &requested)
      try require(code == KERN_INVALID_ARGUMENT, "ordinary object purge was not refused")
      let retained = try counts()
      try require(retained.resident == Self.slots && retained.swapped == 0, "refused object changed")
      try verifyAllCanaries()
      records.append([
        "purgeNativeCode": code, "ordinaryObjectUnchanged": retained.record,
        "allCanariesVerified": true,
      ])
    } else if purgable {
      for cycle in 0..<3 {
        try time()
        // The only vCPU is synchronously back on its owner thread; there is no DMA or NIC.
        try unmapDataHVF()
        for slot in 0..<Self.slots {
          if slot & 127 == 0 { try time() }
          try guestRead(slot * Self.page, expected: nil)
        }
        let occupied = try counts()
        try require(occupied.resident == Self.slots && occupied.swapped == 0,
                    "HVF-held object not fully resident")
        let began = ContinuousClock.now
        try setState(VM_PURGABLE_EMPTY)
        try setState(VM_PURGABLE_NONVOLATILE)
        let duration = began.duration(to: .now).components
        let empty = try counts()
        try require(empty.resident == 0 && empty.swapped == 0, "backing remains after EMPTY")
        let after = try TaskMemory.capture()
        try mapDataHVF()
        let afterMap = try counts()
        // Actual guest reads precede all host zero probes and refills.
        try guestVerify(true)
        // Probe only AFTER the direct, nonfaulting memory-entry residency observation.
        try verifyZero()
        try fill()
        let regrown = try counts()
        try require(regrown.resident == Self.slots && regrown.swapped == 0, "regrowth missing")
        try verifyAllCanaries()
        try guestVerify(false)
        records.append([
          "cycle": cycle, "occupied": occupied.record, "emptyBeforeRead": empty.record,
          "regrown": regrown.record, "afterDiscardTask": after.record,
          "discardNanoseconds": duration.seconds * 1_000_000_000 + duration.attoseconds / 1_000_000_000,
          "zeroFillVerified": true, "mappingAndPortRemainOwned": true,
          "fullRegrowthCanaryVerified": true,
          "guestZeroAndRegrowthVerified": true,
          "allStage2FaultsVerified": Self.slots,
          "afterColdStage2Remap": afterMap.record,
        ])
      }
    } else {
      try require(profile == "shared-held", "unknown profile")
      for slot in stride(from: 1, to: Self.slots, by: 2) {
        if slot & 255 == 1 { try time() }
        var target = address + UInt64(slot * Self.page)
        try check(
          mach_vm_map(
            mach_task_self_, &target, UInt64(Self.page), 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
            mach_port_t(MACH_PORT_NULL), 0, 0, VM_PROT_NONE, VM_PROT_NONE, VM_INHERIT_NONE), "placeholder")
      }
      let after = try TaskMemory.capture()
      let retained = try counts()
      try require(retained.resident == Self.slots && retained.swapped == 0, "held pages not resident")
      for slot in [1, 3, 2047, 4095] {
        try time()
        var probe: UInt64 = 0
        try check(
          mach_vm_map(
            mach_task_self_, &probe, UInt64(Self.page), 0, VM_FLAGS_ANYWHERE, entry,
            UInt64(slot * Self.page), 0, VM_PROT_READ, VM_PROT_READ, VM_INHERIT_NONE), "probe-map")
        scratch = probe
        guard let pointer = UnsafePointer<UInt64>(bitPattern: UInt(probe)) else {
          throw Failure.invariant("probe pointer")
        }
        try verifyCanary(pointer, slot: slot)
        try check(mach_vm_deallocate(mach_task_self_, probe, UInt64(Self.page)), "probe-drop")
        scratch = nil
      }
      records.append([
        "beforeTask": before.record, "afterPlaceholderTask": after.record,
        "residentObjectAfterPlaceholdersBeforeProbe": retained.record,
        "candidateBytesUnmappedFromHostView": Self.bytes / 2,
        "retiredOffsetCanaryProbes": 4, "canaryVerified": true,
      ])
    }
    _ = try pressure()
    try time()
  }

  func close() -> [String] {
    var errors: [String] = []
    // Do not release any backing until the actual vCPU and VM have been destroyed.
    if let cpu {
      let code = hv_vcpu_destroy(cpu)
      if code != 0 { return ["hv-cpu-destroy \(code)"] }
      self.cpu = nil
      exitInfo = nil
    }
    if vmCreated {
      if dataMapped {
        let code = hv_vm_unmap(Self.dataGPA, Self.bytes)
        if code != 0 { errors.append("hv-data-unmap \(code)") } else { dataMapped = false }
      }
      if codeMapped {
        let code = hv_vm_unmap(Self.codeGPA, Self.page)
        if code != 0 { errors.append("hv-code-unmap \(code)") } else { codeMapped = false }
      }
      let code = hv_vm_destroy()
      if code != 0 { return errors + ["hv-vm-destroy \(code)"] }
      vmCreated = false
      dataMapped = false
      codeMapped = false
    }
    if let codePointer {
      let code = hv_vm_deallocate(codePointer, Self.page)
      if code != 0 { errors.append("hv-code-drop \(code)") } else { self.codePointer = nil }
    }
    if let scratch {
      let code = mach_vm_deallocate(mach_task_self_, scratch, UInt64(Self.page))
      if code != 0 { errors.append("scratch-drop \(code)") } else { self.scratch = nil }
    }
    if let base {
      let code = mach_vm_deallocate(mach_task_self_, base, UInt64(Self.bytes))
      if code != 0 { errors.append("arena-drop \(code)") } else { self.base = nil }
    }
    if entry != 0 {
      let code = mach_port_deallocate(mach_task_self_, entry)
      if code != 0 { errors.append("entry-drop \(code)") } else { entry = 0 }
    }
    return errors
  }
  var nativeRecord: [String: Any] {
    ["guestRuns": guestRuns, "cpuDestroyed": cpu == nil, "vmDestroyed": !vmCreated,
     "codeBackingReleased": codePointer == nil, "cpuCount": 1, "nicCount": 0,
     "guestExecutedOwnedData": guestExecutedData, "dataStage2Permissions": 7,
     "hostDataMaximumProtection": 3]
  }
}

@main struct MachBackingControlLab {
  static func main() throws {
    guard CommandLine.arguments.count == 2,
      CommandLine.arguments[1] == "purgable-hvf"
    else { throw Failure.invariant("fixed profile required") }
    let fixture = Fixture()
    var primary = ""
    do { try fixture.run(CommandLine.arguments[1]) } catch { primary = String(describing: error) }
    let cleanup = fixture.close()
    let record: [String: Any] = [
      "profile": CommandLine.arguments[1], "objectBytes": Fixture.bytes,
      "hostPageBytes": Fixture.page, "records": fixture.records,
      "primaryError": primary, "cleanupErrors": cleanup,
      "native": fixture.nativeRecord,
      "physicalGlobalFreeBytesAttributed": NSNull(),
      "scope": "Synthetic64MiB one-vCPU zero-NIC HVF only; no Linux, ClickHouse or adoption",
    ]
    let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
    guard data.count <= 64 << 10 else { throw Failure.invariant("bounded output") }
    FileHandle.standardOutput.write(data)
    if !primary.isEmpty || !cleanup.isEmpty { exit(1) }
  }
}
