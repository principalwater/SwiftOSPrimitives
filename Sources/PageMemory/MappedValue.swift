/// A mapping or constructor failure, without boxing an untyped error in the allocation path.
public enum MappedValueError<Factory: Error>: Error {
  case memory(PageMemoryError)
  case factory(Factory)
}
extension MappedValueError: Equatable where Factory: Equatable {}

/// Owns one initialized value in a stable virtual-memory slot.
/// Moving this owner does not move that slot. Safe access cannot replace or take its value.
/// This is not physical pinning, DMA registration or self-referential in-place construction.
/// Allocate, read, release and destruction require a context allowing faults or blocking work.
@safe public struct MappedValue<Element: ~Copyable>: ~Copyable {
  private var mapping: PageMapping
  private var pointer: UnsafeMutablePointer<Element>?

  /// Page-rounded backing bytes, including alignment padding.
  public var mappedByteCount: Int { mapping.byteCount }
  /// True once the value has been destroyed, even if unmapping needs a retry.
  public var isDestroyed: Bool { unsafe pointer == nil }
  /// True only after the backing mapping has also been released.
  public var isReleased: Bool { mapping.isReleased }

  private init(mapping: consuming PageMapping, pointer: UnsafeMutablePointer<Element>) {
    self.mapping = mapping
    unsafe self.pointer = pointer
  }

  /// Maps backing before calling the factory; mapping refusal never calls it.
  /// The factory constructs a value which is then moved into its final slot.
  /// Its work and the value's destructor may allocate or block independently.
  /// Preserves constructor and mapping failures as distinct typed cases, including Never factories.
  public static func allocate<Failure: Error>(
    maximumMappedBytes: Int = 64 * 1024 * 1024,
    context: AllocationContext = .mayBlock,
    initializing makeValue: () throws(Failure) -> Element
  ) throws(MappedValueError<Failure>) -> MappedValue {
    let mapping: PageMapping
    do throws(PageMemoryError) {
      mapping = try makeMapping(maximumMappedBytes: maximumMappedBytes, context: context)
    } catch { throw .memory(error) }
    let value: Element
    do throws(Failure) { value = try makeValue() } catch { throw .factory(error) }
    return initialize(mapping: mapping, value: value)
  }

  private static func makeMapping(maximumMappedBytes: Int, context: AllocationContext)
    throws(PageMemoryError) -> PageMapping
  {
    try PageMapping.allocate(
      byteCount: MemoryLayout<Element>.stride, maximumMappedBytes: maximumMappedBytes,
      context: context, alignment: MemoryLayout<Element>.alignment)
  }

  private static func initialize(
    mapping: consuming PageMapping, value: consuming Element
  ) -> MappedValue {
    let alignment = MemoryLayout<Element>.alignment
    let base = unsafe mapping.address.unsafelyUnwrapped
    let address = UInt(bitPattern: base)
    let offset = Int((0 &- address) & UInt(alignment - 1))
    // Anonymous backing is still unbound: no byte view exists alongside the live typed slot.
    let pointer = unsafe base.advanced(by: offset).bindMemory(to: Element.self, capacity: 1)
    unsafe pointer.initialize(to: value)
    return unsafe MappedValue(mapping: mapping, pointer: pointer)
  }

  /// Lends a read-only, single-element span; safe loans cannot escape this callback.
  /// No move-out or mutable loan of the slot is supplied. Reference interiors may still mutate.
  public borrowing func withValue<Result: ~Copyable>(_ body: (Span<Element>) -> Result)
    throws(PageMemoryError) -> Result
  {
    guard let pointer = unsafe pointer else { throw .unavailable }
    let rawView = unsafe Span(_unsafeStart: UnsafePointer(pointer), count: 1)
    let view = unsafe _overrideLifetime(rawView, borrowing: self)
    return body(view)
  }

  /// Destroys the value exactly once, then releases backing; failed unmap is retryable.
  /// Nonblocking admission refuses before either destruction or unmapping.
  public mutating func release(context: AllocationContext = .mayBlock) throws(PageMemoryError) {
    if mapping.isReleased { return }
    guard context == .mayBlock else { throw .operationMayBlock }
    if let pointer = unsafe pointer {
      // Retire before destruction; the mapping has no byte access or reinitialization API.
      unsafe self.pointer = nil
      _ = unsafe pointer.deinitialize(count: 1)
    }
    try mapping.release()
  }

  deinit {
    if let pointer = unsafe pointer { _ = unsafe pointer.deinitialize(count: 1) }
    // PageMapping supplies the final unmap fallback after Element destruction.
  }
}
