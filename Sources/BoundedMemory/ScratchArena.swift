/// A refused request never invokes the callback or modifies storage.
public enum AllocationFailure: Equatable, Sendable {
  case invalidSize, invalidAlignment, capacityExceeded
}
/// The payload must be escapable; a borrowed arena or span cannot be returned.
public enum AllocationOutcome<Value: ~Copyable>: ~Copyable {
  case allocated(Value)
  case refused(AllocationFailure)
}
extension AllocationOutcome: Copyable where Value: Copyable {}

/// Synchronous scratch reservations in exclusively borrowed, initialized byte storage.
/// No heap allocation, syscall, synchronization or address relocation is performed.
/// Bytes retain their previous contents; this is not a typed-object allocator or physical pin.
/// `Lifetimes` is experimental: build and verify with the pinned Swift 6.4.1 toolchain.
@safe public struct ScratchArena: ~Copyable, ~Escapable {
  private var storage: MutableSpan<UInt8>
  /// Takes the byte loan, preserving its original owner lifetime and exclusivity.
  @_lifetime(copy storage)
  public init(storage: consuming MutableSpan<UInt8>) { self.storage = storage }
  /// Total byte capacity; alignment may consume additional padding from the actual base address.
  public var capacity: Int { storage.count }

  /// Lends an aligned region and a disjoint remainder for nested reservations.
  /// Callback errors propagate unchanged. No cursor or live reservation survives the callback.
  /// Refusal is fallible; callback allocation/blocking behavior remains the caller's responsibility.
  public mutating func withAllocation<Value: ~Copyable, Failure: Error>(
    byteCount: Int, alignment: Int = 1,
    _ body: (inout MutableSpan<UInt8>, inout ScratchArena) throws(Failure) -> Value
  ) throws(Failure) -> AllocationOutcome<Value> {
    guard byteCount > 0 else { return .refused(.invalidSize) }
    guard alignment > 0, alignment & (alignment - 1) == 0 else {
      return .refused(.invalidAlignment)
    }
    return try storage.withUnsafeMutableBufferPointer { buffer throws(Failure) in
      guard let base = buffer.baseAddress else { return .refused(.capacityExceeded) }
      // Align the actual address, not just an offset into a potentially unaligned buffer.
      let padding = Int((0 &- UInt(bitPattern: base)) & UInt(alignment - 1))
      guard padding <= buffer.count, byteCount <= buffer.count - padding else {
        return .refused(.capacityExceeded)
      }
      // The guards prove padding + byteCount <= count <= Int.max; wrapping cannot occur.
      let offset = padding &+ byteCount
      // Checked extents partition one exclusive loan; both children remain inside this callback.
      var bytes = unsafe MutableSpan(_unsafeStart: base.advanced(by: padding), count: byteCount)
      let rest = unsafe MutableSpan(
        _unsafeStart: base.advanced(by: offset), count: buffer.count &- offset)
      var remainder = ScratchArena(storage: consume rest)
      return .allocated(try body(&bytes, &remainder))
    }
  }
}
