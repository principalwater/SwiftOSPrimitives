#if canImport(Darwin)
  import Darwin
#elseif os(Linux) && canImport(Glibc)
  import Glibc
#elseif os(Linux) && canImport(Musl)
  import Musl
#elseif os(Linux) && canImport(SwiftGlibc)
  import SwiftGlibc
#elseif os(Linux) && canImport(SwiftMusl)
  import SwiftMusl
#else
  #error("PageMemory currently supports Darwin and Linux.")
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
/// Selects native reclamation accounting without promising immediate physical release.
public enum ReclamationStrategy: Sendable { case platformDefault, reusable }
public struct Reclamation: Equatable, Sendable {
  public let advisedBytes: Int
  public let semantics: ReclamationSemantics
  /// Darwin reusable-ledger accounting was applied; not a physical-release claim.
  public let usesReusableAccounting: Bool
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
  #if canImport(Darwin)
    private var reusableAdviceMayApply = false
  #endif
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
    let pageSize = Int(sysconf(Int32(_SC_PAGESIZE)))
    guard pageSize > 0 else {
      throw .systemCall(operation: .pageSize, code: NativeMemorySystem.errorCode)
    }
    let (sum, overflow) = byteCount.addingReportingOverflow(pageSize - 1)
    guard !overflow else { throw .invalidSize }
    let mapped = sum / pageSize * pageSize
    guard mapped <= maximumMappedBytes else { throw .limitExceeded }
    let raw = unsafe mmap(nil, mapped, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0)
    guard unsafe !NativeMemorySystem.mappingFailed(raw) else {
      throw .systemCall(operation: .map, code: NativeMemorySystem.errorCode)
    }
    // Swift cannot represent a nonoptional pointer to address zero. Reject and release it.
    guard let raw = unsafe raw else {
      guard munmap(nil, mapped) == 0 else {
        throw .systemCall(operation: .unmap, code: NativeMemorySystem.errorCode)
      }
      throw .systemCall(operation: .map, code: EFAULT)
    }
    // MAP_ANONYMOUS initializes bytes to zero; only this owner binds and unmaps them.
    let pointer = unsafe raw.bindMemory(to: UInt8.self, capacity: mapped)
    return unsafe PageRegion(
      pointer: pointer, byteCount: byteCount, mapped: mapped, pageSize: pageSize)
  }
  deinit {
    // Explicit release reports errors; destruction supplies a final fallback.
    if let pointer = unsafe pointer { _ = unsafe munmap(pointer, mappedByteCount) }
  }

  /// Result is Escapable: a safe Span cannot be returned or retained outside the callback.
  public borrowing func withBytes<Result: ~Copyable>(_ body: (Span<UInt8>) -> Result)
    throws(PageMemoryError) -> Result
  {
    guard let pointer = unsafe pointer else { throw .unavailable }
    guard contents == .active else { throw .contentsDiscarded }
    let rawView = unsafe Span(_unsafeStart: UnsafePointer(pointer), count: byteCount)
    let view = unsafe _overrideLifetime(rawView, borrowing: self)
    return body(view)
  }
  public mutating func withMutableBytes<Result: ~Copyable>(
    _ body: (inout MutableSpan<UInt8>) -> Result
  )
    throws(PageMemoryError) -> Result
  {
    guard let pointer = unsafe pointer else { throw .unavailable }
    guard contents == .active else { throw .contentsDiscarded }
    let rawView = unsafe MutableSpan(_unsafeStart: pointer, count: byteCount)
    var view = unsafe _overrideLifetime(rawView, mutating: &self)
    return body(&view)
  }

  /// Lends bytes to a throwing callback and propagates its original error.
  public borrowing func withReadAccess<Result: ~Copyable, Failure: Error>(
    _ body: (Span<UInt8>) throws(Failure) -> Result
  ) throws -> Result {
    let outcome: Swift.Result<Result, Failure> = try withBytes { bytes in
      Swift.Result(catching: { () throws(Failure) -> Result in try body(bytes) })
    }
    return try outcome.get()
  }

  /// Mutably lends bytes to a throwing callback; mutations made before a throw are retained.
  public mutating func withWriteAccess<Result: ~Copyable, Failure: Error>(
    _ body: (inout MutableSpan<UInt8>) throws(Failure) -> Result
  ) throws -> Result {
    let outcome: Swift.Result<Result, Failure> = try withMutableBytes { bytes in
      Swift.Result(catching: { () throws(Failure) -> Result in try body(&bytes) })
    }
    return try outcome.get()
  }

  /// Retires all contents, including on advisory failure. Reset is required before access.
  public mutating func discardContents() throws(PageMemoryError) -> Reclamation {
    try discardContents(using: .platformDefault)
  }

  /// Retires contents using the chosen native strategy; failure also retires access.
  public mutating func discardContents(using strategy: ReclamationStrategy)
    throws(PageMemoryError) -> Reclamation
  {
    guard let pointer = unsafe pointer else { throw .unavailable }
    #if canImport(Darwin)
      let advice = strategy == .reusable ? MADV_FREE_REUSABLE : MADV_FREE
      let semantics: ReclamationSemantics = .lazyFree
    #else
      let advice = MADV_DONTNEED
      let semantics: ReclamationSemantics = .discardAndZeroOnDemand
    #endif
    #if canImport(Darwin)
      if contents == .discarded && (strategy != .reusable || reusableAdviceMayApply) {
        return Reclamation(
          advisedBytes: 0, semantics: .lazyFree, usesReusableAccounting: reusableAdviceMayApply)
      }
    #else
      if contents == .discarded {
        return Reclamation(advisedBytes: 0, semantics: semantics, usesReusableAccounting: false)
      }
    #endif
    // Advice can fail after partial effects. Retire contents before the syscall.
    contents = .retired
    #if canImport(Darwin)
      if strategy == .platformDefault && reusableAdviceMayApply {
        guard unsafe madvise(pointer, mappedByteCount, MADV_FREE_REUSE) == 0 else {
          throw .systemCall(operation: .advise, code: NativeMemorySystem.errorCode)
        }
        reusableAdviceMayApply = false
      }
      if strategy == .reusable { reusableAdviceMayApply = true }
    #endif
    guard unsafe madvise(pointer, mappedByteCount, advice) == 0 else {
      throw .systemCall(operation: .advise, code: NativeMemorySystem.errorCode)
    }
    contents = .discarded
    #if canImport(Darwin)
      let reusable = reusableAdviceMayApply
    #else
      let reusable = false
    #endif
    return Reclamation(
      advisedBytes: mappedByteCount, semantics: semantics, usesReusableAccounting: reusable)
  }

  /// Initializes logical bytes. Darwin touches pages; Linux uses zero-on-demand when possible.
  /// If Linux advice is refused, explicit zeroing restores this exclusively owned live mapping.
  public mutating func resetToZero() throws(PageMemoryError) {
    guard let pointer = unsafe pointer else { throw .unavailable }
    #if os(Linux)
      // Successful DONTNEED already guarantees zero-on-demand without a second syscall.
      if contents == .discarded {
        contents = .active
        return
      }
    #endif
    contents = .retired
    #if canImport(Darwin)
      if reusableAdviceMayApply {
        guard unsafe madvise(pointer, mappedByteCount, MADV_FREE_REUSE) == 0 else {
          throw .systemCall(operation: .advise, code: NativeMemorySystem.errorCode)
        }
        reusableAdviceMayApply = false
      }
      _ = unsafe memset(pointer, 0, byteCount)
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
    #if canImport(Darwin)
      typealias ResidencyByte = Int8
    #else
      typealias ResidencyByte = UInt8
    #endif
    // Bounded temporary storage avoids an Array owner and supports the iOS 18 target.
    return try withUnsafeTemporaryAllocation(of: ResidencyByte.self, capacity: 1024) {
      storage throws(PageMemoryError) -> Int in
      guard let vector = storage.baseAddress else { throw .unavailable }
      var offset = 0
      var resident = 0
      while offset < mappedByteCount {
        let length = min(mappedByteCount - offset, 1024 * pageSize)
        guard unsafe mincore(pointer.advanced(by: offset), length, vector) == 0 else {
          throw .systemCall(operation: .residency, code: NativeMemorySystem.errorCode)
        }
        // mincore initialized exactly the entries for this page-rounded extent.
        for index in 0..<(length / pageSize) { resident += Int(unsafe vector[index]) & 1 }
        offset += length
      }
      return resident
    }
  }
  /// On failure ownership remains retryable; success is idempotent.
  public mutating func release() throws(PageMemoryError) {
    guard let pointer = unsafe pointer else { return }
    guard unsafe munmap(pointer, mappedByteCount) == 0 else {
      throw .systemCall(operation: .unmap, code: NativeMemorySystem.errorCode)
    }
    unsafe self.pointer = nil
  }
}
