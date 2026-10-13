import _Volatile

/// A compiler/codegen fixture, not a general driver API or a synchronization primitive.
/// The caller must supply a live, aligned, valid UInt32 register mapping.
/// Volatile preserves accesses; device/DMA ordering and mapping ownership are external contracts.
@unsafe
@inline(__always)
@_cdecl("register_trace32")
public func registerTrace32(_ address: UnsafeMutablePointer<UInt32>, _ value: UInt32) -> UInt32 {
  let register = unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(bitPattern: address))
  register.store(value)
  let first = register.load()
  register.store(value &+ 1)
  let second = register.load()
  return first ^ second
}
