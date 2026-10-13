#if canImport(Darwin)
  import Darwin
#elseif os(Linux) && canImport(Glibc)
  import Glibc
#elseif os(Linux) && canImport(Musl)
  import Musl
#elseif os(Windows)
  import WinSDK
#else
  #error("PageMemory supports Darwin, Linux and Windows.")
#endif

public enum PageMemoryError: Error, Equatable, Sendable {
  case invalidSize, limitExceeded, unavailable, contentsDiscarded
  case systemCall(operation: Operation, code: Int32)
  public enum Operation: String, Sendable { case pageSize, map, advise, unmap, residency }
}
public enum ReclamationSemantics: String, Sendable {
  case discardAndZeroOnDemand
  case lazyFree
}
public struct Reclamation: Equatable, Sendable {
  public let advisedBytes: Int
  public let semantics: ReclamationSemantics
  /// Advice success does not measure physical/resident bytes actually released.
  public let physicalReleasedBytes: Int? = nil
}
/// One owner of anonymous private pages, with synchronous lifetime-bounded access.
/// The type exposes no raw pointer and is deliberately not Sendable.
@safe public struct PageRegion: ~Copyable {
  private var pointer: UnsafeMutablePointer<UInt8>?
  public let byteCount: Int
  public let mappedByteCount: Int
  public let pageSize: Int
  private enum Contents { case active, retired, discarded }
  private var contents: Contents
  public var isReleased: Bool { unsafe pointer == nil }

  private init(pointer: UnsafeMutablePointer<UInt8>, byteCount: Int, mapped: Int, pageSize: Int) {
    unsafe self.pointer = unsafe pointer
    self.byteCount = byteCount
    mappedByteCount = mapped
    self.pageSize = pageSize
    contents = .active
  }
  /// The limit includes page rounding and applies to this region, not the entire process.
  public static func allocate(byteCount: Int, maximumMappedBytes: Int = 64 * 1024 * 1024)
    throws(PageMemoryError) -> PageRegion
  {
    guard byteCount > 0, maximumMappedBytes > 0 else { throw .invalidSize }
    #if os(Windows)
      var information = unsafe SYSTEM_INFO()
      unsafe GetSystemInfo(&information)
      let pageSize = unsafe Int(information.dwPageSize)
      guard pageSize > 0 else {
        throw .systemCall(operation: .pageSize, code: Int32(ERROR_INVALID_DATA))
      }
    #else
      let pageSize = Int(sysconf(Int32(_SC_PAGESIZE)))
      guard pageSize > 0 else { throw .systemCall(operation: .pageSize, code: errno) }
    #endif
    let (sum, overflow) = byteCount.addingReportingOverflow(pageSize - 1)
    guard !overflow else { throw .invalidSize }
    let mapped = sum / pageSize * pageSize
    guard mapped <= maximumMappedBytes else { throw .limitExceeded }
    #if os(Windows)
      // With a nil address, size rounds to pages; only the base uses allocation granularity.
      guard
        let raw = unsafe VirtualAlloc(
          nil, SIZE_T(mapped), DWORD(MEM_RESERVE | MEM_COMMIT), DWORD(PAGE_READWRITE))
      else { throw .systemCall(operation: .map, code: Int32(bitPattern: GetLastError())) }
    #else
      let raw = unsafe mmap(nil, mapped, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0)
      guard unsafe raw != MAP_FAILED else { throw .systemCall(operation: .map, code: errno) }
      // Swift cannot represent a nonoptional pointer to address zero. Reject and release it.
      guard let raw = unsafe raw else {
        guard munmap(nil, mapped) == 0 else {
          throw .systemCall(operation: .unmap, code: errno)
        }
        throw .systemCall(operation: .map, code: EFAULT)
      }
    #endif
    // Anonymous private allocation initializes bytes to zero; only this owner releases them.
    let pointer = unsafe raw.bindMemory(to: UInt8.self, capacity: mapped)
    return unsafe PageRegion(
      pointer: pointer, byteCount: byteCount, mapped: mapped, pageSize: pageSize)
  }
  deinit {
    // Explicit release reports errors; destruction supplies a final fallback.
    if let pointer = unsafe pointer {
      #if os(Windows)
        _ = unsafe VirtualFree(pointer, 0, DWORD(MEM_RELEASE))
      #else
        _ = unsafe munmap(pointer, mappedByteCount)
      #endif
    }
  }

  /// Result is Escapable: a safe Span cannot be returned or retained outside the callback.
  public borrowing func withBytes<Result>(_ body: (Span<UInt8>) -> Result)
    throws(PageMemoryError) -> Result
  {
    guard let pointer = unsafe pointer else { throw .unavailable }
    guard contents == .active else { throw .contentsDiscarded }
    let rawView = unsafe Span(_unsafeStart: UnsafePointer(pointer), count: byteCount)
    let view = unsafe _overrideLifetime(rawView, borrowing: self)
    return body(view)
  }
  public mutating func withMutableBytes<Result>(_ body: (inout MutableSpan<UInt8>) -> Result)
    throws(PageMemoryError) -> Result
  {
    guard let pointer = unsafe pointer else { throw .unavailable }
    guard contents == .active else { throw .contentsDiscarded }
    let rawView = unsafe MutableSpan(_unsafeStart: pointer, count: byteCount)
    var view = unsafe _overrideLifetime(rawView, mutating: &self)
    return body(&view)
  }

  /// Retires all contents, including on advisory failure. Reset is required before access.
  public mutating func discardContents() throws(PageMemoryError) -> Reclamation {
    guard let pointer = unsafe pointer else { throw .unavailable }
    #if canImport(Darwin)
      let advice = MADV_FREE
      let semantics: ReclamationSemantics = .lazyFree
    #elseif os(Linux)
      let advice = MADV_DONTNEED
      let semantics: ReclamationSemantics = .discardAndZeroOnDemand
    #else
      let semantics: ReclamationSemantics = .discardAndZeroOnDemand
    #endif
    if contents == .discarded { return Reclamation(advisedBytes: 0, semantics: semantics) }
    // Advice can fail after partial effects. Retire contents before the syscall.
    contents = .retired
    #if os(Windows)
      // MEM_RESET does not guarantee zeros. Decommit keeps our reservation for reset/release.
      guard unsafe VirtualFree(pointer, SIZE_T(mappedByteCount), DWORD(MEM_DECOMMIT)) else {
        throw .systemCall(operation: .advise, code: Int32(bitPattern: GetLastError()))
      }
    #else
      guard unsafe madvise(pointer, mappedByteCount, advice) == 0 else {
        throw .systemCall(operation: .advise, code: errno)
      }
    #endif
    contents = .discarded
    return Reclamation(advisedBytes: mappedByteCount, semantics: semantics)
  }

  /// Initializes logical bytes. Darwin touches pages; Linux and Windows use zero-on-demand.
  /// If Linux advice is refused, explicit zeroing restores this exclusively owned live mapping.
  public mutating func resetToZero() throws(PageMemoryError) {
    guard let pointer = unsafe pointer else { throw .unavailable }
    contents = .retired
    #if canImport(Darwin)
      _ = unsafe memset(pointer, 0, byteCount)
    #elseif os(Windows)
      // Also decommit active or partially retired contents before recommitting zeroed pages.
      guard unsafe VirtualFree(pointer, SIZE_T(mappedByteCount), DWORD(MEM_DECOMMIT)) else {
        throw .systemCall(operation: .advise, code: Int32(bitPattern: GetLastError()))
      }
      guard
        let raw = unsafe VirtualAlloc(
          pointer, SIZE_T(mappedByteCount), DWORD(MEM_COMMIT), DWORD(PAGE_READWRITE))
      else { throw .systemCall(operation: .map, code: Int32(bitPattern: GetLastError())) }
      unsafe self.pointer = raw.bindMemory(to: UInt8.self, capacity: mappedByteCount)
    #else
      if unsafe madvise(pointer, mappedByteCount, MADV_DONTNEED) != 0 {
        _ = unsafe memset(pointer, 0, byteCount)
      }
    #endif
    contents = .active
  }
  /// Page residency is separate from allocator accounting and physical footprint.
  public borrowing func residentPageCount() throws(PageMemoryError) -> Int {
    guard let pointer = unsafe pointer else { throw .unavailable }
    #if os(Windows)
      var vector = unsafe [PSAPI_WORKING_SET_EX_INFORMATION](
        repeating: PSAPI_WORKING_SET_EX_INFORMATION(),
        count: min(1024, mappedByteCount / pageSize))
      var offset = 0
      var resident = 0
      while offset < mappedByteCount {
        let count = unsafe min((mappedByteCount - offset) / pageSize, vector.count)
        for index in 0..<count {
          unsafe vector[index].VirtualAddress = UnsafeMutableRawPointer(
            pointer.advanced(by: offset + index * pageSize))
        }
        let (succeeded, errorCode) = vector.withUnsafeMutableBytes { buffer in
          let succeeded = unsafe K32QueryWorkingSetEx(
            GetCurrentProcess(), buffer.baseAddress,
            DWORD(count * MemoryLayout<PSAPI_WORKING_SET_EX_INFORMATION>.stride))
          return (succeeded, succeeded ? DWORD(0) : GetLastError())
        }
        guard succeeded else {
          throw .systemCall(operation: .residency, code: Int32(bitPattern: errorCode))
        }
        // Only the documented Valid bit indicates residency; commitment alone does not.
        for index in 0..<count {
          resident += unsafe Int(vector[index].VirtualAttributes.Flags & 1)
        }
        offset += count * pageSize
      }
      return resident
    #else
      #if canImport(Darwin)
        var vector = [Int8](repeating: 0, count: min(1024, mappedByteCount / pageSize))
      #else
        var vector = [UInt8](repeating: 0, count: min(1024, mappedByteCount / pageSize))
      #endif
      var offset = 0
      var resident = 0
      while offset < mappedByteCount {
        let length = min(mappedByteCount - offset, vector.count * pageSize)
        guard unsafe mincore(pointer.advanced(by: offset), length, &vector) == 0 else {
          throw .systemCall(operation: .residency, code: errno)
        }
        for index in 0..<(length / pageSize) { resident += Int(vector[index]) & 1 }
        offset += length
      }
      return resident
    #endif
  }
  /// On failure ownership remains retryable; success is idempotent.
  public mutating func release() throws(PageMemoryError) {
    guard let pointer = unsafe pointer else { return }
    #if os(Windows)
      guard unsafe VirtualFree(pointer, 0, DWORD(MEM_RELEASE)) else {
        throw .systemCall(operation: .unmap, code: Int32(bitPattern: GetLastError()))
      }
    #else
      guard unsafe munmap(pointer, mappedByteCount) == 0 else {
        throw .systemCall(operation: .unmap, code: errno)
      }
    #endif
    unsafe self.pointer = nil
  }
}
