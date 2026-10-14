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
  private(set) var isReleased = false

  private init(address: UnsafeMutableRawPointer?, byteCount: Int, pageSize: Int) {
    unsafe self.address = address
    self.byteCount = byteCount
    self.pageSize = pageSize
  }

  static func allocate(
    byteCount: Int, maximumMappedBytes: Int, context: AllocationContext, alignment: Int = 1
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
    let padding = alignment <= pageSize ? 0 : alignment - 1
    let (padded, paddingOverflow) = byteCount.addingReportingOverflow(padding)
    let (sum, overflow) = padded.addingReportingOverflow(pageSize - 1)
    guard !paddingOverflow, !overflow else { throw .invalidSize }
    let mapped = sum / pageSize * pageSize
    guard mapped <= maximumMappedBytes else { throw .limitExceeded }
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
    guard unsafe munmap(address, byteCount) == 0 else {
      throw .systemCall(operation: .unmap, code: NativeMemorySystem.errorCode)
    }
    unsafe self.address = nil
    isReleased = true
  }

  deinit {
    // Explicit release reports failure; destruction makes one final, non-looping attempt.
    if !isReleased { _ = unsafe munmap(address, byteCount) }
  }
}
