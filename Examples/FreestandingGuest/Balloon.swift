import GuestABI
import _Volatile

#if GUEST_HOST_BALLOON && (GUEST_BALLOON_WRAP || GUEST_BALLOON_WRAP_INFLATE_ID || GUEST_BALLOON_WRAP_DEFLATE_ID || GUEST_BALLOON_WRAP_LENGTH || GUEST_BALLOON_WRAP_STALE || GUEST_BALLOON_WRAP_NO_DEFLATE || GUEST_BALLOON_DIRTY_DONOR)
  #error("Host balloon and full-wrap modes must be separate builds")
#endif

@unsafe private func waitBalloonTarget(_ device: UInt, pages: UInt32) {
  let frequency = guest_timer_frequency()
  guard frequency >= 1000, frequency <= 10_000_000_000 else { finish("HOST_CLOCK_FAIL\n") }
  let (deadline, overflow) = guest_timer_counter().addingReportingOverflow(frequency * 5)
  guard !overflow else { finish("HOST_CLOCK_FAIL\n") }
  var lastRequested: UInt32 = 0
  while guest_timer_counter() < deadline {
    let pending = unsafe mmioWord(device + 0x60).load()
    unsafe mmioWord(device + 0x64).store(pending & 3)
    let generation = unsafe mmioWord(device + 0xfc).load()
    let requested = unsafe mmioWord(device + 0x100).load()
    guest_device_barrier()
    if generation == (unsafe mmioWord(device + 0xfc).load()) {
      lastRequested = requested
      if requested == pages { return }
    }
  }
  finish(
    lastRequested == 0 || lastRequested == 4 ? "HOST_TARGET_TIMEOUT\n" : "HOST_TARGET_MISMATCH\n")
}

// The donor extent is16KiB-aligned and exclusively retained by this guest ledger.
@unsafe private func verifyDonor(_ pages: UInt, word: UInt64, marker: StaticString) {
  for offset in stride(from: 0, to: 4 * 4096, by: 8) {
    let value = unsafe VolatileMappedRegister<UInt64>(unsafeBitPattern: pages + UInt(offset)).load()
    if value != word { finish(marker) }
  }
}

@unsafe private func verifyBalloonPFNs(_ ring: UInt, firstFrame: UInt) {
  for index in 0..<4 {
    guard
      unsafe mmioWord(ring + 256 + UInt(index * 4)).load()
        == UInt32(firstFrame) + UInt32(index)
    else { finish("BALLOON_LIST_FAIL\n") }
  }
}

// Real used-ring completion; the optional host mode waits for QMP-driven target changes.
@unsafe func checkBalloon(_ raw: UnsafeMutableRawPointer, count: Int) {
  let address = UInt(bitPattern: raw)
  unsafe validateFrameBacking(raw, count: count)
  let device = unsafe findVirtio(5)
  guard device != 0 else { finish("BALLOON_MISSING\n") }
  unsafe initializeVirtio(device)
  var metadata: InlineArray<17, UInt64> = .init(repeating: 0)
  guard var ledger = FrameLedger(metadata: metadata.mutableSpan, firstFrame: address / 4096),
    case .reserved(let rings) = ledger.reserve(frameCount: 2),
    case .reserved(let donated) = ledger.reserve(frameCount: 4, alignment: 4),
    donated.firstFrame <= UInt(UInt32.max) - 3
  else { finish("BALLOON_CAPACITY_FAIL\n") }
  let ring = rings.firstFrame * 4096
  let pages = donated.firstFrame * 4096
  guard pages % 16384 == 0 else { finish("BALLOON_ALIGNMENT_FAIL\n") }
  _ = unsafe guestMemoryFill(raw, 0x47, UInt(count * 4096))
  _ = unsafe guestMemoryFill(UnsafeMutableRawPointer(bitPattern: ring), 0, 2 * 4096)
  unsafe prepareVirtioQueue(device, index: 0, ring: ring)
  unsafe prepareVirtioQueue(device, index: 1, ring: ring + 4096)
  guard unsafe mmioWord(device + 0x100).load() == 0 else { finish("BALLOON_TARGET_FAIL\n") }
  for index in 0..<4 {
    unsafe mmioWord(ring + 256 + UInt(index * 4)).store(UInt32(donated.firstFrame) + UInt32(index))
  }
  unsafe mmioWord(device + 0x70).store(15)
  #if GUEST_HOST_BALLOON
    guard
      let budget = BalloonBudget(
        installedBytes: 64 * 1024 * 1024, minimumResidentBytes: 64 * 1024 * 1024 - 16384,
        granuleBytes: 16384, maximumStepBytes: 16384),
      budget.target(observedResidentBytes: 64 * 1024 * 1024, requestedResidentBytes: 1)
        == 64 * 1024 * 1024 - 16384
    else { finish("HOST_BUDGET_FAIL\n") }
    let cycles = 10
  #elseif GUEST_BALLOON_WRAP || GUEST_BALLOON_WRAP_INFLATE_ID || GUEST_BALLOON_WRAP_DEFLATE_ID || GUEST_BALLOON_WRAP_LENGTH || GUEST_BALLOON_WRAP_STALE || GUEST_BALLOON_WRAP_NO_DEFLATE || GUEST_BALLOON_DIRTY_DONOR
    let cycles = 65540
  #else
    let cycles = 1
  #endif
  #if GUEST_STALE_COMPLETION
    let initialCount: UInt64 = 1
  #else
    let initialCount: UInt64 = 0
  #endif
  guard var inflate = SplitRingSequence(queueSize: 8, completedCount: initialCount),
    var deflate = SplitRingSequence(queueSize: 8)
  else { finish("VIRTIO_SEQUENCE_FAIL\n") }
  let frequency = guest_timer_frequency()
  guard frequency >= 1000, frequency <= 10_000_000_000 else { finish("BALLOON_CLOCK_FAIL\n") }
  let (deadline, overflow) = guest_timer_counter().addingReportingOverflow(frequency * 120)
  guard !overflow else { finish("BALLOON_CLOCK_FAIL\n") }
  for cycle in 0..<cycles {
    guard guest_timer_counter() < deadline else { finish("BALLOON_WRAP_TIMEOUT\n") }
    #if GUEST_HOST_BALLOON
      emit("HOST_READY\n")
      unsafe waitBalloonTarget(device, pages: 4)
    #endif
    // Erase before handing these exclusive pages to the device; no later read while inflated.
    _ = unsafe guestMemoryFill(UnsafeMutableRawPointer(bitPattern: pages), 0, 4 * 4096)
    #if GUEST_BALLOON_DIRTY_DONOR
      if inflate.completedCount == 65536 {
        emit("BALLOON_DIRTY_DONOR_65536\n")
        unsafe VolatileMappedRegister<UInt64>(unsafeBitPattern: pages + 4 * 4096 - 8).store(1)
      }
    #endif
    unsafe verifyDonor(pages, word: 0, marker: "BALLOON_ERASE_FAIL\n")
    guest_device_barrier()
    #if GUEST_BALLOON_WRAP_STALE
      if inflate.completedCount == 65536 {
        emit("BALLOON_STALE_65536\n")
        unsafe mmioHalf(ring + 162).store(65535)
      }
    #endif
    unsafe verifyBalloonPFNs(ring, firstFrame: donated.firstFrame)
    // Virtio permits voluntary supply when requested >= actual (both initially zero).
    // Do not access donated pages from publication through deflate acknowledgement.
    _ = unsafe postVirtioBuffer(
      device, queue: 0, ring: ring, buffer: ring + 256, length: 16, deviceWrites: false,
      sequence: &inflate, timeoutMarker: "BALLOON_INFLATE_TIMEOUT\n")
    unsafe verifyBalloonPFNs(ring, firstFrame: donated.firstFrame)
    unsafe mmioWord(device + 0x104).store(4)
    guest_device_barrier()
    #if GUEST_HOST_BALLOON
      emit("HOST_INFLATED\n")
      unsafe waitBalloonTarget(device, pages: 0)
    #else
      if cycle == 0 { emit("BALLOON_INFLATED\n") }
    #endif
    guard unsafe mmioWord(device + 0x100).load() == 0 else { finish("BALLOON_TARGET_FAIL\n") }
    #if GUEST_BALLOON_BAD_PFN_DEFLATE
      emit("BALLOON_PFN_BEFORE_DEFLATE_INJECT\n")
      unsafe mmioWord(ring + 256).store(UInt32(donated.firstFrame) + 1)
    #endif
    unsafe verifyBalloonPFNs(ring, firstFrame: donated.firstFrame)
    #if GUEST_BALLOON_NO_DEFLATE
      _ = unsafe postVirtioBuffer(
        device, queue: 1, ring: ring + 4096, buffer: ring + 256, length: 16,
        deviceWrites: false, sequence: &deflate, publish: false,
        timeoutMarker: "BALLOON_DEFLATE_TIMEOUT\n")
      finish("BALLOON_NEGATIVE_BYPASSED\n")
    #else
      #if GUEST_BALLOON_WRAP_NO_DEFLATE
        let publish = deflate.completedCount != 65536
        if !publish { emit("BALLOON_WITHHOLD_DEFLATE_65536\n") }
      #else
        let publish = true
      #endif
      _ = unsafe postVirtioBuffer(
        device, queue: 1, ring: ring + 4096, buffer: ring + 256, length: 16, deviceWrites: false,
        sequence: &deflate, publish: publish, timeoutMarker: "BALLOON_DEFLATE_TIMEOUT\n")
      unsafe verifyBalloonPFNs(ring, firstFrame: donated.firstFrame)
      unsafe mmioWord(device + 0x104).store(0)
      guest_device_barrier()
      // Deflated memory is uninitialized: reinitialize before any CPU read or allocator reuse.
      _ = unsafe guestMemoryFill(UnsafeMutableRawPointer(bitPattern: pages), 0x35, 4 * 4096)
      unsafe verifyDonor(pages, word: 0x3535_3535_3535_3535, marker: "BALLOON_REUSE_FAIL\n")
      #if GUEST_HOST_BALLOON
        emit("HOST_DEFLATED\n")
      #endif
    #endif
  }
  guard inflate.completedCount == UInt64(cycles), deflate.completedCount == UInt64(cycles),
    inflate.wireIndex == UInt16(truncatingIfNeeded: cycles),
    deflate.wireIndex == UInt16(truncatingIfNeeded: cycles),
    unsafe mmioHalf(ring + 162).load() == inflate.wireIndex,
    unsafe mmioHalf(ring + 130).load() == inflate.wireIndex,
    unsafe mmioHalf(ring + 4096 + 162).load() == deflate.wireIndex,
    unsafe mmioHalf(ring + 4096 + 130).load() == deflate.wireIndex
  else { finish("BALLOON_WRAP_COUNT_FAIL\n") }
  unsafe resetVirtio(device)
  for queue in UInt32(0)..<2 {
    unsafe mmioWord(device + 0x30).store(queue)
    #if GUEST_BALLOON_RESET_READY
      if queue == 1 {
        emit("BALLOON_RESET_QUEUE_INJECT\n")
        unsafe mmioWord(device + 0x44).store(1)
      }
    #endif
    guard unsafe mmioWord(device + 0x44).load() == 0 else { finish("BALLOON_RESET_QUEUE_FAIL\n") }
  }
  // The successful reset is the boundary before freeing tickets; check adjacent RAM too.
  for offset in stride(from: 0, to: count * 4096, by: 8) {
    let current = address + UInt(offset)
    if (ring..<(ring + 2 * 4096)).contains(current)
      || (pages..<(pages + 4 * 4096)).contains(current)
    {
      continue
    }
    let value = unsafe VolatileMappedRegister<UInt64>(unsafeBitPattern: current).load()
    if value != 0x4747_4747_4747_4747 { finish("BALLOON_BOUNDS_FAIL\n") }
  }
  guard case .released = ledger.release(donated), case .released = ledger.release(rings),
    ledger.availableCount == count
  else { finish("BALLOON_RELEASE_FAIL\n") }
  #if GUEST_BALLOON_WRAP
    guard inflate.completedCount == 65540, deflate.completedCount == 65540 else {
      finish("BALLOON_WRAP_COUNT_FAIL\n")
    }
    emit("BALLOON_WRAP_PASS 65540 65540\n")
  #endif
  emit("BALLOON_PASS\n")
}
