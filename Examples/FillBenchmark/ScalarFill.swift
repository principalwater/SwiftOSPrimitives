import _Volatile

// Standalone byte-store reference for the optional benchmark, not a package implementation.
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
  while remaining > 0 {
    unsafe VolatileMappedRegister<UInt8>(unsafeBitPattern: address).store(byte)
    address += 1
    remaining -= 1
  }
  return unsafe destination
}
