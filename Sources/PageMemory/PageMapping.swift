#if os(Linux) && hasFeature(Embedded)
  import NativePOSIX
#elseif canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#else
  import Musl
#endif

// Byte-free backing owner: mapping ownership must not imply a live UInt8 or Element binding.
// Generic noncopyable owners need this storage metadata across a framework boundary.
@usableFromInline @safe struct PageMapping: ~Copyable {
  private(set) var address: UnsafeMutableRawPointer?
  let byteCount: Int
  let pageSize: Int
  let isPurgeable: Bool
  private(set) var isReleased = false

  private init(
    address: UnsafeMutableRawPointer?, byteCount: Int, pageSize: Int, isPurgeable: Bool = false
  ) {
    unsafe self.address = address
    self.byteCount = byteCount
    self.pageSize = pageSize
    self.isPurgeable = isPurgeable
  }

  static func allocate(
    byteCount: Int, maximumMappedBytes: Int, context: AllocationContext, alignment: Int = 1,
    backing: PageBacking = .anonymous
  )
    throws(PageMemoryError) -> PageMapping
  {
    guard byteCount > 0, maximumMappedBytes > 0, alignment > 0,
      alignment & (alignment - 1) == 0
    else { throw .invalidSize }
    guard context == .mayBlock else { throw .operationMayBlock }
    let pageSize = Int(sysconf(Int32(_SC_PAGESIZE)))
    guard pageSize > 0, pageSize & (pageSize - 1) == 0 else {
      throw .systemCall(operation: .pageSize, code: NativeMemorySystem.errorCode)
    }
    // This is backing padding, not an aligned base; MappedValue aligns its typed slot.
    let padding = alignment <= pageSize ? 0 : alignment - 1
    let (padded, paddingOverflow) = byteCount.addingReportingOverflow(padding)
    let (sum, overflow) = padded.addingReportingOverflow(pageSize - 1)
    guard !paddingOverflow, !overflow else { throw .invalidSize }
    let mapped = sum / pageSize * pageSize
    guard mapped <= maximumMappedBytes else { throw .limitExceeded }
    #if canImport(Darwin)
      if backing == .reclaimable {
        #if os(macOS)
          var address: mach_vm_address_t = 0
          let code = unsafe mach_vm_allocate(
            mach_task_self_, &address, mach_vm_size_t(mapped), VM_FLAGS_ANYWHERE | VM_FLAGS_PURGABLE
          )
        #else
          var address: vm_address_t = 0
          guard let size = vm_size_t(exactly: mapped) else { throw .invalidSize }
          let code = unsafe vm_allocate(
            mach_task_self_, &address, size, VM_FLAGS_ANYWHERE | VM_FLAGS_PURGABLE)
        #endif
        guard code == KERN_SUCCESS else { throw .machCall(operation: .map, code: code) }
        var mapping = unsafe PageMapping(
          address: UnsafeMutableRawPointer(bitPattern: UInt(address)), byteCount: mapped,
          pageSize: pageSize, isPurgeable: true)
        guard address != 0 else {
          try mapping.release()
          throw .unavailable
        }
        return mapping
      }
    #endif
    let raw = unsafe mmap(nil, mapped, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0)
    guard unsafe !NativeMemorySystem.mappingFailed(raw) else {
      throw .systemCall(operation: .map, code: NativeMemorySystem.errorCode)
    }
    var mapping = unsafe PageMapping(address: raw, byteCount: mapped, pageSize: pageSize)
    // Address zero cannot form a Swift typed pointer, but this handle still owns its release.
    guard unsafe raw != nil else {
      try mapping.release()
      throw .systemCall(operation: .map, code: EFAULT)
    }
    return mapping
  }

  mutating func release(context: AllocationContext = .mayBlock) throws(PageMemoryError) {
    if isReleased { return }
    guard context == .mayBlock else { throw .operationMayBlock }
    #if canImport(Darwin)
      if isPurgeable {
        #if os(macOS)
          let code = unsafe mach_vm_deallocate(
            mach_task_self_, mach_vm_address_t(UInt(bitPattern: address)), mach_vm_size_t(byteCount)
          )
        #else
          let code = unsafe vm_deallocate(
            mach_task_self_, vm_address_t(UInt(bitPattern: address)), vm_size_t(byteCount))
        #endif
        guard code == KERN_SUCCESS else { throw .machCall(operation: .unmap, code: code) }
        unsafe self.address = nil
        isReleased = true
        return
      }
    #endif
    guard unsafe munmap(address, byteCount) == 0 else {
      throw .systemCall(operation: .unmap, code: NativeMemorySystem.errorCode)
    }
    unsafe self.address = nil
    isReleased = true
  }

  deinit {
    // Explicit release reports failure; destruction makes one final, non-looping attempt.
    if !isReleased {
      #if canImport(Darwin)
        if isPurgeable {
          #if os(macOS)
            _ = unsafe mach_vm_deallocate(
              mach_task_self_, mach_vm_address_t(UInt(bitPattern: address)),
              mach_vm_size_t(byteCount)
            )
          #else
            _ = unsafe vm_deallocate(
              mach_task_self_, vm_address_t(UInt(bitPattern: address)), vm_size_t(byteCount))
          #endif
        } else {
          _ = unsafe munmap(address, byteCount)
        }
      #else
        _ = unsafe munmap(address, byteCount)
      #endif
    }
  }

  #if canImport(Darwin)
    enum PurgeState { case nonvolatile, empty }

    mutating func setPurgeableState(_ requested: PurgeState) throws(PageMemoryError) {
      var state = requested == .empty ? VM_PURGABLE_EMPTY : VM_PURGABLE_NONVOLATILE
      #if os(macOS)
        let code = unsafe mach_vm_purgable_control(
          mach_task_self_, mach_vm_address_t(UInt(bitPattern: address)), VM_PURGABLE_SET_STATE,
          &state
        )
      #else
        let code = unsafe vm_purgable_control(
          mach_task_self_, vm_address_t(UInt(bitPattern: address)), VM_PURGABLE_SET_STATE, &state)
      #endif
      guard code == KERN_SUCCESS else { throw .machCall(operation: .purgeState, code: code) }
    }
  #endif
}
