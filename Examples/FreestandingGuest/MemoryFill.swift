import _Volatile

/// Guest-local RAM fill; the caller supplies an exclusive valid writable extent.
/// Volatile stores prevent this libc implementation from optimizing into a recursive memset.
@c(guest_memory_fill)
@inline(never)
@unsafe public func guestMemoryFill(
  _ destination: UnsafeMutableRawPointer?, _ value: Int32, _ count: UInt
) -> UnsafeMutableRawPointer? {
  guard count > 0 else { return unsafe destination }
  guard let destination = unsafe destination, count <= UInt(Int.max) else {
    preconditionFailure("Invalid RAM fill extent")
  }
  var address = UInt(bitPattern: destination)
  guard count <= UInt.max - address else { preconditionFailure("RAM fill address overflow") }
  var remaining = count
  let byte = UInt8(truncatingIfNeeded: value)
  while remaining > 0 && address % 8 != 0 {
    unsafe VolatileMappedRegister<UInt8>(unsafeBitPattern: address).store(byte)
    address += 1
    remaining -= 1
  }
  let word = UInt64(byte) * 0x0101_0101_0101_0101
  while remaining >= 8 {
    unsafe VolatileMappedRegister<UInt64>(unsafeBitPattern: address).store(word)
    address += 8
    remaining -= 8
  }
  while remaining > 0 {
    unsafe VolatileMappedRegister<UInt8>(unsafeBitPattern: address).store(byte)
    address += 1
    remaining -= 1
  }
  return unsafe destination
}

#if GUEST_BUILD
  // Only the freestanding executable supplies libc ABI symbols, never a package product.
  @c(memset)
  @unsafe public func guestMemset(
    _ destination: UnsafeMutableRawPointer?, _ value: Int32, _ count: UInt
  ) -> UnsafeMutableRawPointer? {
    unsafe guestMemoryFill(destination, value, count)
  }
#endif
