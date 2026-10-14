import _Volatile

/// Guest-local non-overlapping RAM copy; callers provide valid readable/writable extents.
/// Volatile operations prevent this libc implementation from becoming a recursive memcpy.
@c(guest_memory_copy)
@inline(never)
@unsafe public func guestMemoryCopy(
  _ destination: UnsafeMutableRawPointer?, _ source: UnsafeRawPointer?, _ count: UInt
) -> UnsafeMutableRawPointer? {
  guard count > 0 else { return unsafe destination }
  guard let destination = unsafe destination, let source = unsafe source,
    count <= UInt(Int.max)
  else { preconditionFailure("Invalid RAM copy extent") }
  var target = UInt(bitPattern: destination)
  var origin = UInt(bitPattern: source)
  guard count <= UInt.max - target, count <= UInt.max - origin else {
    preconditionFailure("RAM copy address overflow")
  }
  if target == origin { return unsafe destination }
  guard target + count <= origin || origin + count <= target else {
    preconditionFailure("Overlapping RAM copy extents")
  }
  var remaining = count
  if (target ^ origin) & 7 == 0 {
    while remaining > 0 && target & 7 != 0 {
      let byte = unsafe VolatileMappedRegister<UInt8>(unsafeBitPattern: origin).load()
      unsafe VolatileMappedRegister<UInt8>(unsafeBitPattern: target).store(byte)
      target += 1
      origin += 1
      remaining -= 1
    }
    while remaining >= 8 {
      let word = unsafe VolatileMappedRegister<UInt64>(unsafeBitPattern: origin).load()
      unsafe VolatileMappedRegister<UInt64>(unsafeBitPattern: target).store(word)
      target += 8
      origin += 8
      remaining -= 8
    }
  }
  while remaining > 0 {
    let byte = unsafe VolatileMappedRegister<UInt8>(unsafeBitPattern: origin).load()
    unsafe VolatileMappedRegister<UInt8>(unsafeBitPattern: target).store(byte)
    target += 1
    origin += 1
    remaining -= 1
  }
  return unsafe destination
}

#if GUEST_BUILD
  @c(memcpy)
  @unsafe public func guestMemcpy(
    _ destination: UnsafeMutableRawPointer?, _ source: UnsafeRawPointer?, _ count: UInt
  ) -> UnsafeMutableRawPointer? {
    unsafe guestMemoryCopy(destination, source, count)
  }
#endif
