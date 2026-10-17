// No runtime, allocator, libc, or OS: executes on a real EL1 vCPU.
@_cdecl("swift_guest")
public func guest(_ address: UInt64, _ pages: UInt64, _ salt: UInt64, _ operation: UInt64) -> UInt64
{
  guard pages == 16 || pages == 512 || pages == 16384, operation <= 2,
    let base = UnsafeMutablePointer<UInt64>(bitPattern: UInt(address))
  else { return 1 }
  var index: UInt64 = 0
  while index < pages * 512 {
    let slot = base.advanced(by: Int(index))
    if operation == 0 {
      if slot.pointee != 0 { return 2 }
    } else if operation == 1 {
      slot.pointee = salt ^ index
    } else if slot.pointee != salt ^ index {
      return 3
    }
    index &+= 1
  }
  return 0
}
