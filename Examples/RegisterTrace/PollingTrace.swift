import _Volatile

// Compile-only comparisons: no real device address is read on the host.
@c(uart_poll_plain)
@unsafe public func pollPlain(_ flags: UnsafePointer<UInt8>) {
  while unsafe flags.pointee & 0x10 != 0 {}
}
@c(uart_poll_volatile)
@unsafe public func pollVolatile(_ flags: UnsafePointer<UInt8>) {
  let register = unsafe VolatileMappedRegister<UInt8>(unsafeBitPattern: UInt(bitPattern: flags))
  while register.load() & 0x10 != 0 {}
}
