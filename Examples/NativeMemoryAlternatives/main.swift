import Darwin

private enum Refusal: Error {
  case native(Int32)
  case contract
}

@main struct NativeAlternatives {
  static func main() {
    do { try run() } catch {
      print("NATIVE_ALTERNATIVES_REFUSED \(error)")
      exit(1)
    }
  }
  private static func zero(_ owner: inout PageRegion) throws {
    let result = try owner.withMutableBytes { bytes in
      bytes.withUnsafeMutableBufferPointer { buffer in
        unsafe madvise(buffer.baseAddress, buffer.count, MADV_ZERO)
      }
    }
    guard result == 0 else { throw Refusal.native(errno) }
  }
  private static func regionInfo(_ base: UInt, extent: Int) throws
    -> vm_region_submap_info_data_64_t
  {
    var address = mach_vm_address_t(base)
    var size: mach_vm_size_t = 0
    var depth: natural_t = 0
    var info = vm_region_submap_info_data_64_t()
    let capacity = MemoryLayout<vm_region_submap_info_data_64_t>.size / MemoryLayout<integer_t>.size
    var count = mach_msg_type_number_t(capacity)
    let code = withUnsafeMutablePointer(to: &info) { pointer in
      unsafe pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) { words in
        unsafe mach_vm_region_recurse(mach_task_self_, &address, &size, &depth, words, &count)
      }
    }
    guard code == KERN_SUCCESS else { throw Refusal.native(code) }
    // This macOS27 control requests the actual SDK27 V3 layout, not guessed offsets.
    guard count == capacity, address == base, size >= extent, info.is_submap == 0,
      info.protection & (VM_PROT_READ | VM_PROT_WRITE) == VM_PROT_READ | VM_PROT_WRITE
    else { throw Refusal.contract }
    return info
  }
  private static func purgeState(_ base: UInt) throws -> Int32 {
    var state: Int32 = 0
    let code = unsafe mach_vm_purgable_control(
      mach_task_self_, mach_vm_address_t(base), VM_PURGABLE_GET_STATE, &state)
    guard code == KERN_SUCCESS else { throw Refusal.native(code) }
    return state & VM_PURGABLE_STATE_MASK
  }
  private static func regionControl() throws {
    var owner = try PageRegion.allocate(byteCount: 2 * 1_048_576, backing: .reclaimable)
    let base = try owner.withMutableBytes { bytes in
      for index in 0..<bytes.count { bytes[index] = 73 }
      return bytes.withUnsafeMutableBufferPointer { UInt(bitPattern: $0.baseAddress) }
    }
    let warm = try regionInfo(base, extent: owner.mappedByteCount)
    guard try purgeState(base) == VM_PURGABLE_NONVOLATILE, warm.pages_resident > 0,
      warm.pages_swapped_out == 0, warm.user_wired_count == 0, warm.pages_wired == 0,
      warm.shadow_depth == 0
    else { throw Refusal.contract }
    try owner.eraseContents()
    _ = try owner.discardContents()
    let after = try regionInfo(base, extent: owner.mappedByteCount)
    let state = try purgeState(base)
    guard state == VM_PURGABLE_EMPTY, after.pages_resident == 0,
      after.pages_swapped_out == 0, try owner.darwinPageDispositionCounts().presentPages == 0
    else { throw Refusal.contract }
    print(
      "{\"operation\":\"owned_region_control\",\"sdk_layout\":\"V3\","
        + "\"resident_before\":\(warm.pages_resident),\"resident_after\":\(after.pages_resident),"
        + "\"compressed_after\":\(after.pages_swapped_out),\"pages_wired\":\(after.pages_wired),"
        + "\"user_wired_count\":\(after.user_wired_count),\"share_mode\":\(after.share_mode),"
        + "\"ref_count\":\(after.ref_count),\"shadow_depth\":\(after.shadow_depth),"
        + "\"purgeable_state\":\(state),\"physical_released_bytes\":null}")
    try owner.resetToZero()
    try owner.eraseContents()
    try owner.release()
    // A complete one-page mapping avoids assuming mlock preserves larger map entries.
    var wiredOwner = try PageRegion.allocate(byteCount: 1, backing: .reclaimable)
    let wiredBase = try wiredOwner.withMutableBytes { bytes in
      bytes[0] = 73
      return bytes.withUnsafeMutableBufferPointer { UInt(bitPattern: $0.baseAddress) }
    }
    guard unsafe mlock(UnsafeRawPointer(bitPattern: wiredBase), wiredOwner.pageSize) == 0 else {
      throw Refusal.native(errno)
    }
    let wired = try regionInfo(wiredBase, extent: wiredOwner.mappedByteCount)
    guard wired.pages_wired == 1, wired.user_wired_count > 0 else { throw Refusal.contract }
    try wiredOwner.eraseContents()
    _ = try wiredOwner.discardContents()
    let retained = try regionInfo(wiredBase, extent: wiredOwner.mappedByteCount)
    guard retained.pages_resident == 1, retained.pages_wired == 1,
      try purgeState(wiredBase) == VM_PURGABLE_EMPTY
    else { throw Refusal.contract }
    guard unsafe munlock(UnsafeRawPointer(bitPattern: wiredBase), wiredOwner.pageSize) == 0 else {
      throw Refusal.native(errno)
    }
    _ = try wiredOwner.discardContents()
    let retried = try regionInfo(wiredBase, extent: wiredOwner.mappedByteCount)
    guard retried.pages_resident == 0, retried.pages_wired == 0,
      retried.pages_swapped_out == 0, try wiredOwner.residentPageCount() == 0
    else { throw Refusal.contract }
    print(
      "{\"operation\":\"V3_wired_residue\",\"wired_before\":\(wired.pages_wired),"
        + "\"resident_after_empty\":\(retained.pages_resident),"
        + "\"resident_after_unlock_retry\":\(retried.pages_resident),"
        + "\"wired_after_unlock_retry\":\(retried.pages_wired),\"physical_released_bytes\":null}")
    try wiredOwner.resetToZero()
    try wiredOwner.eraseContents()
    try wiredOwner.release()
  }
  private static func run() throws {
    try regionControl()
    var region = try PageRegion.allocate(byteCount: 2 * 1_048_576)
    let cold = try region.residentPageCount()
    try zero(&region)
    let coldAfter = try region.residentPageCount()
    guard cold == 0, coldAfter == 0 else { throw Refusal.contract }
    try region.withMutableBytes { bytes in
      for index in 0..<bytes.count { bytes[index] = 73 }
    }
    let warm = try region.residentPageCount()
    let before = try ProcessMemorySnapshot.capture()
    try zero(&region)
    let warmAfter = try region.residentPageCount()
    let after = try ProcessMemorySnapshot.capture()
    guard
      try region.withBytes({ bytes in
        for index in 0..<bytes.count { if bytes[index] != 0 { return false } }
        return true
      })
    else { throw Refusal.contract }
    print(
      "{\"operation\":\"MADV_ZERO\",\"cold\":\(cold),\"cold_after\":\(coldAfter),\"warm\":\(warm),\"warm_after\":\(warmAfter),\"rss_before\":\(before.residentBytes),\"rss_after\":\(after.residentBytes),\"zero_verified\":true}"
    )
    try region.eraseContents()
    try region.release()
    guard let zone = unsafe malloc_create_zone(0, 0) else { throw Refusal.contract }
    var blocks = unsafe InlineArray<64, UnsafeMutableRawPointer?>(repeating: nil)
    defer {
      for index in 0..<64 {
        if let pointer = unsafe blocks[index] { unsafe malloc_zone_free(zone, pointer) }
      }
      unsafe malloc_destroy_zone(zone)
    }
    for index in 0..<64 {
      guard let pointer = unsafe malloc_zone_malloc(zone, 65536) else { throw Refusal.contract }
      unsafe blocks[index] = pointer
      _ = unsafe memset(pointer, 73, 65536)
    }
    let liveRelief = unsafe malloc_zone_pressure_relief(zone, 4 * 1_048_576)
    for index in 0..<64 {
      guard let pointer = unsafe blocks[index] else { throw Refusal.contract }
      let bytes = unsafe pointer.assumingMemoryBound(to: UInt8.self)
      for offset in 0..<65536 {
        guard unsafe bytes[offset] == 73 else { throw Refusal.contract }
      }
      guard unsafe memset_s(pointer, 65536, 0, 65536) == 0 else { throw Refusal.contract }
      unsafe malloc_zone_free(zone, pointer)
      unsafe blocks[index] = nil
    }
    let cached = try ProcessMemorySnapshot.capture()
    let freeRelief = unsafe malloc_zone_pressure_relief(zone, 4 * 1_048_576)
    let relieved = try ProcessMemorySnapshot.capture()
    print(
      "{\"operation\":\"malloc_zone_pressure_relief\",\"owned_zone_only\":true,\"live_canary_ok\":true,\"live_reported_bytes\":\(liveRelief),\"freed_reported_bytes\":\(freeRelief),\"cached_rss\":\(cached.residentBytes),\"relieved_rss\":\(relieved.residentBytes),\"physical_released_bytes\":null}"
    )
  }
}
