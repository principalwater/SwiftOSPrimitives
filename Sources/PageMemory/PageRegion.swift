#if os(Linux) && hasFeature(Embedded)
  import NativePOSIX
#elseif canImport(Darwin)
  import Darwin
#elseif os(Linux) && canImport(Glibc)
  import Glibc
#elseif os(Linux) && canImport(Musl)
  import Musl

#else
  #error("PageMemory currently supports Darwin and Linux.")
#endif

public enum PageMemoryError: Error, Equatable, Sendable {
  case invalidSize, limitExceeded, unavailable, contentsDiscarded, operationMayBlock
  case systemCall(operation: Operation, code: Int32)
  case machCall(operation: Operation, code: Int32)
  public enum Operation: String, Sendable {
    case pageSize, map, advise, unmap, residency, purgeState, erase
  }
}
public enum ReclamationSemantics: String, Sendable {
  case discardAndZeroOnDemand
  case lazyFree
  case purgeRequested
}
/// Reclaimable uses an exclusively owned Mach purgeable object on Darwin;
/// Linux uses the existing private anonymous mapping and DONTNEED.
public enum PageBacking: Sendable { case anonymous, reclaimable }
/// Selects native reclamation accounting without promising immediate physical release.
public enum ReclamationStrategy: Sendable { case platformDefault, reusable }
/// Caller-declared execution context; this does not inspect IRQ state or implement Linux GFP.
public enum AllocationContext: Sendable { case mayBlock, nonblocking }
public struct Reclamation: Equatable, Sendable {
  public let advisedBytes: Int
  public let semantics: ReclamationSemantics
  /// Darwin reusable advice was accepted or remains tracked after an earlier request.
  /// Native ledger effects may be skipped; neither accounting nor physical release is measured.
  public let usesReusableAccounting: Bool
  /// Advice success does not measure physical/resident bytes actually released.
  public let physicalReleasedBytes: Int? = nil
}

/// One owner of anonymous private pages, with synchronous lifetime-bounded access.
/// The type exposes no raw pointer and is deliberately not Sendable.
@safe public struct PageRegion: ~Copyable {
  private var mapping: PageMapping
  private var pointer: UnsafeMutablePointer<UInt8>?
  public let byteCount: Int
  public let mappedByteCount: Int
  public let pageSize: Int
  private enum Contents { case active, retired, discarded, releasePending }
  private var contents: Contents
  #if canImport(Darwin)
    private var reusableAdviceMayApply = false
  #endif
  public var isReleased: Bool { unsafe pointer == nil }

  private init(mapping: consuming PageMapping, pointer: UnsafeMutablePointer<UInt8>, byteCount: Int)
  {
    unsafe self.pointer = unsafe pointer
    self.byteCount = byteCount
    mappedByteCount = mapping.byteCount
    pageSize = mapping.pageSize
    self.mapping = mapping
    contents = .active
  }
  /// The limit includes page rounding and applies to this region, not the entire process.
  public static func allocate(
    byteCount: Int, maximumMappedBytes: Int = 64 * 1024 * 1024,
    context: AllocationContext = .mayBlock, backing: PageBacking = .anonymous
  )
    throws(PageMemoryError) -> PageRegion
  {
    let mapping = try PageMapping.allocate(
      byteCount: byteCount, maximumMappedBytes: maximumMappedBytes, context: context,
      backing: backing)
    let raw = unsafe mapping.address.unsafelyUnwrapped
    // Both native anonymous allocation paths initialize bytes to zero.
    let pointer = unsafe raw.bindMemory(to: UInt8.self, capacity: mapping.byteCount)
    return unsafe PageRegion(mapping: mapping, pointer: pointer, byteCount: byteCount)
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
  /// Reclaimable Darwin backing uses EMPTY for either strategy, without reusable accounting.
  /// EMPTY can retain busy/wired pages; observe residency independently before claiming a drop.
  public mutating func discardContents(using strategy: ReclamationStrategy)
    throws(PageMemoryError) -> Reclamation
  {
    guard let pointer = unsafe pointer, contents != .releasePending else { throw .unavailable }
    #if canImport(Darwin)
      if mapping.isPurgeable {
        contents = .retired
        try mapping.setPurgeableState(.empty)
        contents = .discarded
        return Reclamation(
          advisedBytes: mappedByteCount, semantics: .purgeRequested,
          usesReusableAccounting: false)
      }
    #endif
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
  /// This is not secure erasure: Linux can discard dirty frames before overwriting.
  /// Erase sensitive bytes before reset. Calls without a context parameter may block.
  public mutating func resetToZero() throws(PageMemoryError) {
    guard let pointer = unsafe pointer, contents != .releasePending else { throw .unavailable }
    #if os(Linux)
      // Successful DONTNEED already guarantees zero-on-demand without a second syscall.
      if contents == .discarded {
        contents = .active
        return
      }
    #endif
    try prepareForInitialization()
    #if canImport(Darwin)
      // EMPTY can skip pages; never replace this initialization with the Linux fast path.
      _ = unsafe memset(pointer, 0, byteCount)
    #else
      if unsafe madvise(pointer, mappedByteCount, MADV_DONTNEED) != 0 {
        _ = unsafe memset(pointer, 0, byteCount)
      }
    #endif
    contents = .active
  }

  /// Overwrites the entire mapped extent with a native, non-elidable erase.
  /// This cannot erase earlier copies, registers, swap, dumps or device-owned buffers.
  /// Failure retires access; nonblocking refusal preserves the previous state.
  public mutating func eraseContents(context: AllocationContext = .mayBlock)
    throws(PageMemoryError)
  {
    guard let pointer = unsafe pointer, contents != .releasePending else { throw .unavailable }
    guard context == .mayBlock else { throw .operationMayBlock }
    try prepareForInitialization()
    #if canImport(Darwin)
      let code = unsafe memset_s(pointer, mappedByteCount, 0, mappedByteCount)
      guard code == 0 else { throw .systemCall(operation: .erase, code: code) }
    #else
      unsafe explicit_bzero(pointer, mappedByteCount)
    #endif
    contents = .active
  }

  private mutating func prepareForInitialization() throws(PageMemoryError) {
    contents = .retired
    #if canImport(Darwin)
      if mapping.isPurgeable {
        try mapping.setPurgeableState(.nonvolatile)
      } else if reusableAdviceMayApply {
        guard unsafe madvise(pointer, mappedByteCount, MADV_FREE_REUSE) == 0 else {
          throw .systemCall(operation: .advise, code: NativeMemorySystem.errorCode)
        }
        reusableAdviceMayApply = false
      }
    #endif
  }
  /// Page residency is separate from allocator accounting and physical footprint.
  public borrowing func residentPageCount() throws(PageMemoryError) -> Int {
    guard let pointer = unsafe pointer, contents != .releasePending else { throw .unavailable }
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
  /// Success is idempotent; failed unmap allows release retry only, with byte access retired.
  /// Release and destruction do not erase. Destruction may block and cannot report failure.
  public mutating func release(context: AllocationContext = .mayBlock) throws(PageMemoryError) {
    if isReleased { return }
    guard context == .mayBlock else { throw .operationMayBlock }
    // An unmap error does not authorize byte access or reinitializing uncertain backing.
    contents = .releasePending
    try mapping.release(context: context)
    unsafe self.pointer = nil
  }
}
