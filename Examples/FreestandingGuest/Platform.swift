import GuestABI
import _Volatile

// Deterministic test cookie only: this is not entropy or a Linux per-task/per-CPU guard ABI.
@used @section(".data") @_silgen_name("__stack_chk_guard")
nonisolated(unsafe) public var guestTestGuard: UInt64 = 0x7315_9824_abc0_de19

func emit(_ text: StaticString) {
  let flags = unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: 0x0900_0018)
  let data = unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: 0x0900_0000)
  for index in 0..<text.utf8CodeUnitCount {
    while flags.load() & 0x20 != 0 {}
    data.store(UInt32(unsafe text.utf8Start[index]))
  }
}

func finish(_ text: StaticString) -> Never {
  emit(text)
  guest_exit()
}

@c(__stack_chk_fail)
public func guestStackFailure() -> Never { finish("STACK_FAIL\n") }

// Terminal diagnosis only: no exception recovery, interrupt dispatch or context restoration.
@c(guest_trap)
public func guestTrap(_ vector: UInt64, _ syndrome: UInt64, _ address: UInt64) -> Never {
  #if GUEST_TRAP_FAILURE || GUEST_TRAP_OTHER
    if vector == 4 && ((syndrome >> 26) & 0x3f) == 0x3c && (syndrome & 0xffff) == 0x641 {
      finish("BRK_PASS\n")
    }
  #endif
  finish("TRAP\n")
}

@c(guard_probe)
@inline(never) public func guardProbe() -> Int {
  var counter = 0
  return withUnsafeMutablePointer(to: &counter) { pointer in
    unsafe guest_corrupt_guard(UnsafeMutableRawPointer(pointer))
    return unsafe pointer.pointee
  }
}
