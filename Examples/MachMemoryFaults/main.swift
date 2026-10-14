import Darwin

// Standalone serialized linker fixture; these exports never enter package products.
nonisolated(unsafe) private var rejectAllocation = false
nonisolated(unsafe) private var rejectState = false
nonisolated(unsafe) private var rejectRelease = false
nonisolated(unsafe) private var rejectErase = false
nonisolated(unsafe) private var trackedAddress: mach_vm_address_t = 0
nonisolated(unsafe) private var trackedSize = 0
nonisolated(unsafe) private var releaseAttempts = 0
nonisolated(unsafe) private var checkedErase = false

private typealias Allocate =
  @convention(c) (
    mach_port_t, UnsafeMutablePointer<mach_vm_address_t>, mach_vm_size_t, Int32
  ) -> kern_return_t
private typealias State =
  @convention(c) (
    mach_port_t, mach_vm_address_t, Int32, UnsafeMutablePointer<Int32>
  ) -> kern_return_t
private typealias Release =
  @convention(c) (
    mach_port_t, mach_vm_address_t, mach_vm_size_t
  ) -> kern_return_t
private typealias Erase = @convention(c) (UnsafeMutableRawPointer?, Int, Int32, Int) -> Int32

@unsafe private func native<T>(_ name: String, as: T.Type) -> T {
  guard let symbol = unsafe dlsym(UnsafeMutableRawPointer(bitPattern: -1), name) else {
    fatalError("Missing native ABI: " + name)
  }
  return unsafe unsafeBitCast(symbol, to: T.self)
}

@c(swiftos_fault_allocate)
@unsafe public func faultAllocate(
  _ task: mach_port_t, _ address: UnsafeMutablePointer<mach_vm_address_t>,
  _ size: mach_vm_size_t, _ flags: Int32
) -> kern_return_t {
  if unsafe rejectAllocation {
    unsafe rejectAllocation = false
    return KERN_RESOURCE_SHORTAGE
  }
  let code = unsafe native("mach_vm_allocate", as: Allocate.self)(task, address, size, flags)
  if code == KERN_SUCCESS {
    unsafe trackedAddress = address.pointee
    unsafe trackedSize = Int(size)
    // Dirty rounded padding as well as logical bytes to test the complete erase extent.
    if let raw = unsafe UnsafeMutableRawPointer(bitPattern: UInt(address.pointee)) {
      _ = unsafe memset(raw, 91, trackedSize)
    }
  }
  return code
}

@c(swiftos_fault_state)
@unsafe public func faultState(
  _ task: mach_port_t, _ address: mach_vm_address_t, _ control: Int32,
  _ state: UnsafeMutablePointer<Int32>
) -> kern_return_t {
  if unsafe address == trackedAddress && rejectState {
    unsafe rejectState = false
    return KERN_FAILURE
  }
  return unsafe native("mach_vm_purgable_control", as: State.self)(task, address, control, state)
}

@c(swiftos_fault_release)
@unsafe public func faultRelease(
  _ task: mach_port_t, _ address: mach_vm_address_t, _ size: mach_vm_size_t
) -> kern_return_t {
  if unsafe address == trackedAddress {
    unsafe releaseAttempts += 1
    if unsafe rejectRelease {
      unsafe rejectRelease = false
      return KERN_FAILURE
    }
  }
  return unsafe native("mach_vm_deallocate", as: Release.self)(task, address, size)
}

@c(swiftos_fault_erase)
@unsafe public func faultErase(
  _ pointer: UnsafeMutableRawPointer?, _ maximum: Int, _ value: Int32, _ size: Int
) -> Int32 {
  if unsafe UInt(bitPattern: pointer) == UInt(trackedAddress) {
    if unsafe rejectErase {
      unsafe rejectErase = false
      _ = unsafe memset(pointer, 0, size / 2)
      return EINVAL
    }
    guard unsafe maximum == trackedSize && size == trackedSize, value == 0 else { return EINVAL }
  }
  let code = unsafe native("memset_s", as: Erase.self)(pointer, maximum, value, size)
  if code == 0, unsafe UInt(bitPattern: pointer) == UInt(trackedAddress),
    let pointer = unsafe pointer
  {
    let bytes = unsafe pointer.assumingMemoryBound(to: UInt8.self)
    unsafe checkedErase = (0..<size).allSatisfy { unsafe bytes[$0] == 0 }
  }
  return code
}

private enum Failure: Error {
  case contract
  case wiredRetry(Int)
  case unretired
}

private func checkRetired(_ owner: borrowing PageRegion) throws {
  do {
    _ = try owner.withBytes { $0[0] }
    throw Failure.unretired
  } catch PageMemoryError.contentsDiscarded {}
}

@main struct MachMemoryFaults {
  static func main() {
    do { try check() } catch {
      print("MACH_MEMORY_FAULTS_REFUSED \(error)")
      exit(1)
    }
  }
  private static func check() throws {
    unsafe rejectAllocation = true
    do {
      _ = try PageRegion.allocate(byteCount: 1, context: .nonblocking, backing: .reclaimable)
      throw Failure.contract
    } catch PageMemoryError.operationMayBlock {}
    guard unsafe rejectAllocation else { throw Failure.contract }
    do {
      _ = try PageRegion.allocate(byteCount: 1, backing: .reclaimable)
      throw Failure.contract
    } catch PageMemoryError.machCall(operation: .map, code: KERN_RESOURCE_SHORTAGE) {}
    guard unsafe !rejectAllocation else { throw Failure.contract }
    var owner = try PageRegion.allocate(byteCount: 1, backing: .reclaimable)
    unsafe rejectState = true
    do {
      _ = try owner.discardContents()
      throw Failure.contract
    } catch PageMemoryError.machCall(operation: .purgeState, code: KERN_FAILURE) {}
    try checkRetired(owner)
    try owner.resetToZero()
    guard try owner.withBytes({ $0[0] == 0 }) else { throw Failure.contract }
    _ = try owner.discardContents()
    unsafe rejectState = true
    do {
      try owner.resetToZero()
      throw Failure.contract
    } catch PageMemoryError.machCall(operation: .purgeState, code: KERN_FAILURE) {}
    try checkRetired(owner)
    try owner.resetToZero()
    unsafe rejectErase = true
    do {
      try owner.eraseContents()
      throw Failure.contract
    } catch PageMemoryError.systemCall(operation: .erase, code: EINVAL) {}
    try checkRetired(owner)
    try owner.eraseContents()
    guard unsafe checkedErase else { throw Failure.contract }
    unsafe rejectRelease = true
    do {
      try owner.release()
      throw Failure.contract
    } catch PageMemoryError.machCall(operation: .unmap, code: KERN_FAILURE) {}
    guard !owner.isReleased, unsafe releaseAttempts == 1 else { throw Failure.contract }
    try checkRetired(owner)
    do {
      try owner.resetToZero()
      throw Failure.contract
    } catch PageMemoryError.unavailable {}
    do {
      try owner.eraseContents()
      throw Failure.contract
    } catch PageMemoryError.unavailable {}
    try owner.release()
    try owner.release()
    guard owner.isReleased, unsafe releaseAttempts == 2 else { throw Failure.contract }
    var wired = try PageRegion.allocate(byteCount: 1, backing: .reclaimable)
    let locked = try wired.withMutableBytes { bytes in
      bytes[0] = 73
      return bytes.withUnsafeMutableBufferPointer { buffer in
        unsafe mlock(buffer.baseAddress, 1)
      }
    }
    guard locked == 0 else { throw Failure.contract }
    _ = try wired.discardContents()
    guard try wired.residentPageCount() > 0 else { throw Failure.contract }
    guard
      unsafe munlock(UnsafeMutableRawPointer(bitPattern: UInt(trackedAddress)), trackedSize) == 0
    else { throw Failure.contract }
    _ = try wired.discardContents()
    let afterRetry = try wired.residentPageCount()
    guard afterRetry == 0 else { throw Failure.wiredRetry(afterRetry) }
    try checkRetired(wired)
    try wired.resetToZero()
    guard try wired.withBytes({ $0[0] == 0 }) else { throw Failure.contract }
    try wired.release()
    print(
      "MACH_MEMORY_FAULTS_PASS allocation purge reset partialErase roundedErase releaseRetry wiredResidue"
    )
  }
}
