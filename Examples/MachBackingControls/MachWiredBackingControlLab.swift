import Darwin
import Foundation

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

/// No VM, disk, network or foreign memory: this owns one fixed synthetic 64MiB named object.
private final class Fixture {
  static let bytes = 64 << 20
  static let page = 16384
  static let slots = bytes / page
  private let deadline = ContinuousClock.now.advanced(by: .seconds(15))
  private var entry: mach_port_t = 0
  private var base: UInt64?
  private var scratch: UInt64?
  private var wired = false
  private(set) var records: [[String: Any]] = []

  private func check(_ code: kern_return_t, _ operation: String) throws {
    guard code == KERN_SUCCESS else { throw Failure.native(operation, code) }
  }
  private func require(_ value: Bool, _ detail: String) throws {
    guard value else { throw Failure.invariant(detail) }
  }
  private func time() throws {
    try require(ContinuousClock.now < deadline, "original 15s deadline expired")
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
    let purgable = profile == "purgable-wired"
    try require(purgable, "fixed wired profile required")
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
    let before = try TaskMemory.capture()
    if profile == "purgable-wired" {
      try require(mlock(try pointer(), Self.page) == 0, "mlock one owned page refused")
      wired = true
      var requested = VM_PURGABLE_EMPTY
      let code = mach_memory_entry_purgable_control(entry, VM_PURGABLE_SET_STATE, &requested)
      let after = try counts()
      // Deliberately bypass a pre-discard wiring guard on synthetic data only.
      try require(code != KERN_SUCCESS || after.resident != 0 || after.swapped != 0,
                  "wired object unexpectedly fully discarded; negative control inconclusive")
      records.append([
        "wiredBytes": Self.page, "emptyNativeCode": code,
        "beforeDiscard": touched.record, "afterDiscardBeforeRead": after.record,
        "postDiscardGuardMustRefuse": true,
        "allContentNowUntrusted": true,
      ])
      // Do not inspect or reuse any content after this intentionally partial destructive attempt.
      try setState(VM_PURGABLE_NONVOLATILE)
    } else if profile == "ordinary-reject" {
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
        let occupied = try counts()
        let began = ContinuousClock.now
        try setState(VM_PURGABLE_EMPTY)
        try setState(VM_PURGABLE_NONVOLATILE)
        let duration = began.duration(to: .now).components
        let empty = try counts()
        try require(empty.resident == 0 && empty.swapped == 0, "backing remains after EMPTY")
        let after = try TaskMemory.capture()
        // Probe only AFTER the direct, nonfaulting memory-entry residency observation.
        try verifyZero()
        try fill()
        let regrown = try counts()
        try require(regrown.resident == Self.slots && regrown.swapped == 0, "regrowth missing")
        try verifyAllCanaries()
        records.append([
          "cycle": cycle, "occupied": occupied.record, "emptyBeforeRead": empty.record,
          "regrown": regrown.record, "afterDiscardTask": after.record,
          "discardNanoseconds": duration.seconds * 1_000_000_000 + duration.attoseconds / 1_000_000_000,
          "zeroFillVerified": true, "mappingAndPortRemainOwned": true,
          "fullRegrowthCanaryVerified": true,
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
    if wired {
      guard let base, let pointer = UnsafeRawPointer(bitPattern: UInt(base)) else {
        return ["wired mapping lost"]
      }
      guard munlock(pointer, Self.page) == 0 else { return ["munlock \(errno)"] }
      wired = false
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
}

@main struct MachBackingControlLab {
  static func main() throws {
    guard CommandLine.arguments.count == 2,
      CommandLine.arguments[1] == "purgable-wired"
    else { throw Failure.invariant("fixed profile required") }
    let fixture = Fixture()
    var primary = ""
    do { try fixture.run(CommandLine.arguments[1]) } catch { primary = String(describing: error) }
    let cleanup = fixture.close()
    let record: [String: Any] = [
      "profile": CommandLine.arguments[1], "objectBytes": Fixture.bytes,
      "hostPageBytes": Fixture.page, "records": fixture.records,
      "primaryError": primary, "cleanupErrors": cleanup,
      "physicalGlobalFreeBytesAttributed": NSNull(),
      "scope": "Synthetic owned object only; no VM, Linux, ClickHouse, global purge or adoption",
    ]
    let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
    guard data.count <= 64 << 10 else { throw Failure.invariant("bounded output") }
    FileHandle.standardOutput.write(data)
    if !primary.isEmpty || !cleanup.isEmpty { exit(1) }
  }
}
