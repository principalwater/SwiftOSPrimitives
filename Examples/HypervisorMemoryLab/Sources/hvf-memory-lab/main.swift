import Darwin
import Foundation
import Hypervisor
import PageMemory

private enum Failure: Error {
  case arguments, state, geometry, mismatch, observation
  case native(String, Int32)
  case guestResult(UInt64)
  case aliased(UInt32)
}

private func check(_ code: hv_return_t, _ operation: String) throws {
  guard code == HV_SUCCESS else { throw Failure.native(operation, code) }
}

// Private to the finite, synchronous lab. No pointer or mapping escapes to a caller.
private final class Region {
  let address: UInt64
  let size: Int
  var pointer: UnsafeMutableRawPointer?
  var mapped = false
  init(address: UInt64, size: Int) {
    self.address = address
    self.size = size
  }
}

private final class Machine {
  var created = false
  var cpu: hv_vcpu_t?
  var exitInfo: UnsafeMutablePointer<hv_vcpu_exit_t>?
  var running = false
  var regions: [Region] = []
  var alias: (address: UInt64, size: Int)?
  let pageSize = Int(sysconf(Int32(_SC_PAGESIZE)))
  let thread = pthread_self()

  func confined() throws {
    guard pthread_equal(thread, pthread_self()) != 0, !running else { throw Failure.state }
  }

  func allocate(address: UInt64, size: Int) throws -> Region {
    try confined()
    guard created, pageSize == 16384, size > 0, size <= 64 << 20,
      size % pageSize == 0, address % UInt64(pageSize) == 0,
      address <= UInt64.max - UInt64(size),
      regions.allSatisfy({
        $0.pointer == nil || address + UInt64(size) <= $0.address
          || $0.address + UInt64($0.size) <= address
      })
    else { throw Failure.geometry }
    let region = Region(address: address, size: size)
    try check(hv_vm_allocate(&region.pointer, size, 0), "allocate")
    regions.append(region)
    guard let pointer = region.pointer else { throw Failure.state }
    try check(
      hv_vm_map(
        pointer, address, size,
        UInt64(HV_MEMORY_READ | HV_MEMORY_WRITE)), "map")
    region.mapped = true
    return region
  }

  func unmap(_ region: Region) throws {
    try confined()
    guard regions.contains(where: { $0 === region }), region.mapped,
      region.pointer != nil
    else { throw Failure.state }
    try check(hv_vm_unmap(region.address, region.size), "unmap")
    region.mapped = false
  }

  func remap(_ region: Region) throws {
    try confined()
    guard regions.contains(where: { $0 === region }), !region.mapped,
      let pointer = region.pointer
    else { throw Failure.state }
    try check(
      hv_vm_map(
        pointer, region.address, region.size,
        UInt64(HV_MEMORY_READ | HV_MEMORY_WRITE)), "remap")
    region.mapped = true
  }

  func release(_ region: Region) throws {
    try confined()
    guard regions.contains(where: { $0 === region }), !region.mapped,
      let pointer = region.pointer
    else { throw Failure.state }
    try requireExclusive(region)
    try check(hv_vm_deallocate(pointer, region.size), "deallocate")
    region.pointer = nil
  }

  enum Fault { case translation, permission }

  func execute(
    data: Region, operation: UInt64, salt: UInt64, fault: Fault? = nil, offset: UInt64 = 0
  ) throws {
    try confined()
    guard let cpu, let exitInfo, offset < UInt64(data.size), offset % 4096 == 0
    else { throw Failure.state }
    for (reg, value) in [
      (HV_REG_PC, UInt64(0x100000)), (HV_REG_CPSR, 0x3c5),
      (HV_REG_X0, data.address + offset), (HV_REG_X1, UInt64(data.size / 4096)), (HV_REG_X2, salt),
      (HV_REG_X3, operation),
    ] {
      try check(hv_vcpu_set_reg(cpu, reg, value), "set-register")
    }
    try check(hv_vcpu_set_sys_reg(cpu, HV_SYS_REG_SP_EL1, 0x220000), "set-stack")
    try check(hv_vcpu_set_sys_reg(cpu, HV_SYS_REG_CPACR_EL1, 3 << 20), "enable-fp")
    running = true
    let code = hv_vcpu_run(cpu)
    running = false
    try check(code, "run")
    let event = exitInfo.pointee
    guard event.reason == HV_EXIT_REASON_EXCEPTION else { throw Failure.mismatch }
    if let fault {
      let status: UInt64 = fault == .translation ? 0x04 : 0x0c
      guard event.exception.syndrome >> 26 == 0x24,
        event.exception.syndrome & 0x3c == status,
        event.exception.physical_address == data.address + offset
      else { throw Failure.mismatch }
    } else {
      var value: UInt64 = .max
      try check(hv_vcpu_get_reg(cpu, HV_REG_X0, &value), "guest-result")
      guard event.exception.syndrome >> 26 == 0x16 else { throw Failure.mismatch }
      guard value == 0 else { throw Failure.guestResult(value) }
    }
  }

  // Kernel page flags concern this owned allocation, never a guessed VZ helper PID.
  func resident(_ region: Region) throws -> UInt64 {
    try confined()
    guard let pointer = region.pointer else { throw Failure.state }
    func setting(_ name: String) throws -> Int32 {
      var value: Int32 = 0
      var count = MemoryLayout<Int32>.size
      guard sysctlbyname(name, &value, &count, nil, 0) == 0,
        count == MemoryLayout<Int32>.size
      else { throw Failure.observation }
      return value
    }
    let geometry = try setting("vm.self_region_page_size")
    guard geometry == 1 || geometry == pageSize,
      try setting("vm.self_region_footprint") == 0
    else { throw Failure.geometry }
    var present: UInt64 = 0
    try withUnsafeTemporaryAllocation(of: integer_t.self, capacity: 256) { scratch in
      for offset in stride(from: 0, to: region.size, by: 255 * pageSize) {
        scratch.initialize(repeating: .min)
        let bytes = min(region.size - offset, 255 * pageSize)
        let expected = bytes / pageSize
        var count = UInt64(expected + 1)
        try check(
          mach_vm_page_range_query(
            mach_task_self_,
            UInt64(UInt(bitPattern: pointer.advanced(by: offset))), UInt64(bytes),
            UInt64(UInt(bitPattern: scratch.baseAddress!)), &count), "page-query")
        guard count == expected else { throw Failure.observation }
        for index in 0..<expected {
          let flags = scratch[index]
          let invalid =
            VM_PAGE_QUERY_PAGE_PAGED_OUT | VM_PAGE_QUERY_PAGE_FICTITIOUS
            | VM_PAGE_QUERY_PAGE_COPIED | VM_PAGE_QUERY_PAGE_EXTERNAL
          guard flags != .min, flags & invalid == 0 else {
            throw Failure.observation
          }
          if flags & VM_PAGE_QUERY_PAGE_PRESENT != 0 { present += 1 }
        }
      }
    }
    guard try setting("vm.self_region_page_size") == geometry,
      try setting("vm.self_region_footprint") == 0
    else { throw Failure.geometry }
    return present * UInt64(pageSize)
  }

  func backingInfo(_ region: Region) throws -> vm_region_submap_info_data_64_t {
    try confined()
    guard let pointer = region.pointer else { throw Failure.state }
    var start = UInt64(UInt(bitPattern: pointer))
    let original = start
    var length: UInt64 = 0
    var depth: UInt32 = 0
    var info = vm_region_submap_info_data_64_t()
    let capacity =
      MemoryLayout<vm_region_submap_info_data_64_t>.size
      / MemoryLayout<integer_t>.size
    var count = mach_msg_type_number_t(capacity)
    let code = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
        mach_vm_region_recurse(mach_task_self_, &start, &length, &depth, $0, &count)
      }
    }
    try check(code, "backing-info")
    guard count == capacity, start == original, length >= region.size,
      info.is_submap == 0, info.shadow_depth == 0, info.external_pager == 0,
      info.object_id_full != 0, info.pages_swapped_out == 0,
      info.pages_wired == 0, info.user_wired_count == 0
    else { throw Failure.observation }
    return info
  }

  func requireExclusive(_ region: Region) throws {
    let info = try backingInfo(region)
    guard info.ref_count == 1 else { throw Failure.aliased(info.ref_count) }
  }

  func makeAlias(_ region: Region) throws {
    try confined()
    guard alias == nil, let pointer = region.pointer else { throw Failure.state }
    var address: UInt64 = 0
    var current: vm_prot_t = 0
    var maximum: vm_prot_t = 0
    try check(
      mach_vm_remap(
        mach_task_self_, &address, UInt64(region.size), 0,
        VM_FLAGS_ANYWHERE, mach_task_self_, UInt64(UInt(bitPattern: pointer)), 0,
        &current, &maximum, VM_INHERIT_NONE), "make-alias")
    alias = (address, region.size)
  }

  func dropAlias() throws {
    try confined()
    guard let alias else { throw Failure.state }
    try check(mach_vm_deallocate(mach_task_self_, alias.address, UInt64(alias.size)), "drop-alias")
    self.alias = nil
  }

  func requireAbsent(address: UInt64, size: Int) throws {
    var start = address
    var length: UInt64 = 0
    var info = vm_region_basic_info_data_64_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_region_basic_info_data_64_t>.size / MemoryLayout<integer_t>.size)
    var port: mach_port_t = 0
    let code = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        mach_vm_region(
          mach_task_self_, &start, &length,
          VM_REGION_BASIC_INFO_64, $0, &count, &port)
      }
    }
    if port != 0 {
      try check(mach_port_deallocate(mach_task_self_, port), "release-region-port")
    }
    guard
      code == KERN_INVALID_ADDRESS
        || (code == KERN_SUCCESS
          && start >= address + UInt64(size))
    else { throw Failure.observation }
  }

  func close() -> [String] {
    var errors: [String] = []
    do { try confined() } catch { return [String(describing: error)] }
    if let cpu {
      let code = hv_vcpu_destroy(cpu)
      guard code == HV_SUCCESS else { return ["vcpu-destroy \(code)"] }
      self.cpu = nil
      exitInfo = nil
    }
    if alias != nil {
      do { try dropAlias() } catch { errors.append(String(describing: error)) }
    }
    for region in regions.reversed() {
      if region.mapped {
        do { try unmap(region) } catch {
          errors.append(String(describing: error))
          continue
        }
      }
      if region.pointer != nil {
        do { try release(region) } catch { errors.append(String(describing: error)) }
      }
    }
    if created {
      let code = hv_vm_destroy()
      if code == HV_SUCCESS { created = false } else { errors.append("vm-destroy \(code)") }
    }
    return errors
  }
}

@main private struct Lab {
  static func main() {
    do { try run() } catch {
      print("HVF_LAB_FAIL \(error)")
      exit(1)
    }
  }

  private static func run() throws {
    let arguments = CommandLine.arguments
    guard arguments.count == 4, ["release", "held", "corrupt", "alias"].contains(arguments[3])
    else {
      throw Failure.arguments
    }
    let file = try FileHandle(forReadingFrom: URL(filePath: arguments[1]))
    let image: Data
    do {
      image = try file.read(upToCount: 65537) ?? Data()
      try file.close()
    } catch {
      try? file.close()
      throw error
    }
    guard !image.isEmpty, image.count <= 65536 else { throw Failure.arguments }
    let destination = URL(filePath: arguments[2])
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw Failure.arguments
    }
    let mode = arguments[3]
    let vm = Machine()
    var primary = ""
    var samples: [[String: Any]] = []
    var cycles = 0
    var releaseObservations: [UInt64] = []
    do {
      try check(hv_vm_create(nil), "create")
      vm.created = true
      let code = try vm.allocate(address: 0x100000, size: 65536)
      image.withUnsafeBytes {
        code.pointer!.copyMemory(from: $0.baseAddress!, byteCount: image.count)
      }
      sys_icache_invalidate(code.pointer!, image.count)
      try check(
        hv_vm_protect(
          code.address, code.size,
          UInt64(HV_MEMORY_READ | HV_MEMORY_EXEC)), "protect-code-rx")
      try check(
        mach_vm_protect(
          mach_task_self_, UInt64(UInt(bitPattern: code.pointer!)),
          UInt64(code.size), 0, VM_PROT_READ), "protect-code-host-ro")
      _ = try vm.allocate(address: 0x210000, size: 65536)
      let canary = try vm.allocate(address: 0x300000, size: 65536)
      var cpu: hv_vcpu_t = 0
      try check(hv_vcpu_create(&cpu, &vm.exitInfo, nil), "vcpu-create")
      vm.cpu = cpu
      try check(hv_vcpu_set_vtimer_mask(cpu, true), "mask-timer")
      try vm.execute(data: code, operation: 1, salt: 1, fault: .permission)
      let canarySalt: UInt64 = 0x5a5a_5a5a_0000_0000
      try vm.execute(data: canary, operation: 1, salt: canarySalt)
      let size = 64 << 20
      func sample(_ stage: String, _ data: Region) throws {
        let process = try ProcessMemorySnapshot.capture()
        samples.append([
          "stage": stage, "residentOwnedBytes": try vm.resident(data),
          "processResidentBytes": process.residentBytes,
          "physicalFootprintBytes": process.physicalFootprintBytes as Any,
          "backingObjectReferences": try vm.backingInfo(data).ref_count,
        ])
      }
      var held: Region?
      for cycle in 0..<4 {
        guard let cycleStart = try ProcessMemorySnapshot.capture().physicalFootprintBytes
        else { throw Failure.observation }
        let data: Region
        if let held {
          try vm.remap(held)
          data = held
        } else {
          data = try vm.allocate(address: 0x4000_0000, size: size)
        }
        let salt = UInt64(0x1234_5678_0000_0000) + UInt64(cycle)
        try vm.execute(
          data: data, operation: cycle == 0 || mode != "held" ? 0 : 2,
          salt: cycle == 0 || mode != "held" ? salt : salt - 1)
        try vm.execute(data: data, operation: 1, salt: salt)
        if mode == "corrupt" {
          data.pointer!.storeBytes(of: UInt64(0), as: UInt64.self)
        }
        try vm.execute(data: data, operation: 2, salt: salt)
        try sample("written-\(cycle)", data)
        guard try vm.resident(data) == UInt64(size) else { throw Failure.observation }
        // A mapped, quiescent extent must never be freed while a stage-2 alias exists.
        do {
          try vm.release(data)
          throw Failure.mismatch
        } catch Failure.state {}
        try vm.unmap(data)
        try sample("unmapped-\(cycle)", data)
        guard try vm.resident(data) == UInt64(size) else { throw Failure.observation }
        for offset in stride(from: UInt64(0), to: UInt64(size), by: vm.pageSize) {
          try vm.execute(data: data, operation: 0, salt: salt, fault: .translation, offset: offset)
        }
        if mode == "alias" {
          try vm.makeAlias(data)
          try sample("aliased-\(cycle)", data)
          do {
            try vm.release(data)
            throw Failure.mismatch
          } catch Failure.aliased(let count) {
            guard count >= 2 else { throw Failure.observation }
          }
          try vm.dropAlias()
        }
        if mode == "held" {
          try sample("held-unmapped-\(cycle)", data)
          try vm.execute(data: canary, operation: 2, salt: canarySalt)
          guard try vm.resident(canary) == UInt64(canary.size) else { throw Failure.observation }
          held = data
          cycles += 1
          continue
        }
        guard let before = try ProcessMemorySnapshot.capture().physicalFootprintBytes,
          let pointer = data.pointer
        else { throw Failure.observation }
        let oldAddress = UInt64(UInt(bitPattern: pointer))
        try vm.release(data)
        try vm.requireAbsent(address: oldAddress, size: size)
        let process = try ProcessMemorySnapshot.capture()
        guard let after = process.physicalFootprintBytes, before >= after,
          before - after >= UInt64(size), before - after - UInt64(size) <= 65536,
          cycle == 0 || (after > cycleStart ? after - cycleStart : cycleStart - after) <= 65536
        else { throw Failure.observation }
        releaseObservations.append(before - after)
        samples.append([
          "stage": "deallocated-\(cycle)",
          "processResidentBytes": process.residentBytes,
          "physicalFootprintBytes": process.physicalFootprintBytes as Any,
        ])
        try vm.execute(data: canary, operation: 2, salt: canarySalt)
        guard try vm.resident(canary) == UInt64(canary.size) else { throw Failure.observation }
        cycles += 1
      }
    } catch { primary = String(describing: error) }
    let cleanup = vm.close()
    let result: [String: Any] = [
      "mode": mode, "cycles": cycles, "samples": samples,
      "primaryError": primary, "cleanupErrors": cleanup, "vmDestroyed": !vm.created,
      "scope": "owned HVF synthetic EL1 guest; not Apple Container or Linux balloon",
      "physicalReleasedBytes": NSNull(),
      "completedDeallocations": releaseObservations.count,
      "footprintReductionBytesPerCycle": releaseObservations,
      "hostFreeListDelta": NSNull(),
    ]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      .write(to: destination, options: .withoutOverwriting)
    guard primary.isEmpty, cleanup.isEmpty, cycles == 4, !vm.created else {
      throw Failure.mismatch
    }
    print("HVF_NATIVE_PASS \(mode) \(cycles)")
  }
}
