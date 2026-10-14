import GuestABI
import _Volatile

// The counter pointer is valid throughout its enclosing native loan and all token destruction.
@safe private struct GuestToken: ~Copyable {
  let identifier: Int
  let counter: UnsafeMutablePointer<UInt64>
  deinit {
    let register = unsafe VolatileMappedRegister<UInt64>(
      unsafeBitPattern: UInt(bitPattern: counter))
    register.store(register.load() + UInt64(identifier))
  }
}

@c(guest_main)
@unsafe public func guestMain(
  _ raw: UnsafeMutableRawPointer?, _ capacity: Int,
  _ frames: UnsafeMutableRawPointer?, _ frameCount: Int
) -> Never {
  guard let raw = unsafe raw, capacity == 4096 else { finish("BAD_BOOT_EXTENT\n") }
  #if GUEST_GUARD_FAILURE
    _ = guardProbe()
    finish("GUARD_BYPASSED\n")
  #else
    checkTimerIRQ()
    guard let frames = unsafe frames, frameCount == 16 else { finish("BAD_FRAME_EXTENT\n") }
    unsafe checkFrames(frames, count: frameCount)
    unsafe checkDMA(frames, count: frameCount)
    unsafe checkBalloon(frames, count: frameCount)
    let bytes = unsafe raw.initializeMemory(as: UInt8.self, repeating: 71, count: capacity)
    let lengths: InlineArray<7, Int> = [0, 1, 7, 8, 9, 31, 65]
    for offset in 0..<16 {
      for lengthIndex in 0..<7 {
        let length = lengths[lengthIndex]
        _ = unsafe guestMemoryFill(raw, 71, UInt(capacity))
        _ = unsafe guestMemoryFill(raw.advanced(by: offset), 0x123, UInt(length))
        for index in 0..<capacity {
          let expected: UInt8 = (offset..<(offset + length)).contains(index) ? 0x23 : 71
          if unsafe bytes[index] != expected { finish("FILL_FAIL\n") }
        }
      }
    }
    _ = unsafe guestMemoryFill(raw, 71, UInt(capacity))
    var destroyed: UInt64 = 0
    withUnsafeMutablePointer(to: &destroyed) { counter in
      let loan = unsafe MutableSpan(_unsafeStart: bytes.advanced(by: 1), count: capacity - 2)
      let base = UInt(bitPattern: bytes) + 1
      let alignment = MemoryLayout<GuestToken>.alignment
      var first = 0
      while (base + UInt(first)) % UInt(alignment) != 0 { first += 1 }
      let end = first + 4 * MemoryLayout<GuestToken>.stride
      var arena = ScratchArena(storage: consume loan)
      enum Payload: Error { case stopped(Int) }
      for iteration in 0..<100 {
        for count in 0...4 {
          do throws(Payload) {
            let _: AllocationOutcome<Int> = try arena.withTypedAllocation(
              of: GuestToken.self, capacity: 4
            ) { output, _ throws(Payload) in
              for identifier in 1..<(count + 1) {
                output.append(unsafe GuestToken(identifier: identifier, counter: counter))
              }
              throw .stopped(iteration)
            }
            finish("ERROR_LOST\n")
          } catch {
            switch error {
            case .stopped(let value): if value != iteration { finish("ERROR_CHANGED\n") }
            }
          }
          switch arena.withAllocation(
            byteCount: capacity - 2,
            { reserved, _ in
              for index in first..<end { if reserved[index] != 0 { finish("RESTORE_FAIL\n") } }
            })
          {
          case .allocated: break
          case .refused: finish("CAPACITY_LEAK\n")
          }
        }
      }
    }
    let total = withUnsafeMutablePointer(to: &destroyed) { pointer in
      unsafe VolatileMappedRegister<UInt64>(unsafeBitPattern: UInt(bitPattern: pointer)).load()
    }
    if unsafe total != 2000 || bytes[0] != 71 || bytes[capacity - 1] != 71 {
      finish("LIFETIME_FAIL\n")
    }
    #if GUEST_MEMORY_FAILURE
      unsafe VolatileMappedRegister<UInt8>(unsafeBitPattern: UInt(bitPattern: bytes)).store(0)
    #endif
    if unsafe bytes[0] != 71 { finish("MEMORY_FAIL\n") }
    #if GUEST_TRAP_FAILURE
      guest_test_trap()
    #elseif GUEST_TRAP_OTHER
      guest_test_other_trap()
    #else
      #if GUEST_HOST_BALLOON
        // Keep the disposable guest alive for the final actual query and host-owned QMP quit.
        emit("GUEST_PASS\n")
        let (deadline, overflow) = guest_timer_counter().addingReportingOverflow(
          guest_timer_frequency() * 5)
        guard !overflow else { finish("HOST_CLOCK_FAIL\n") }
        while guest_timer_counter() < deadline {}
        finish("HOST_FINAL_TIMEOUT\n")
      #else
        finish("GUEST_PASS\n")
      #endif
    #endif
  #endif
}
