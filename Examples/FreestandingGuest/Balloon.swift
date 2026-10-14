import GuestABI
import _Volatile

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

// Real used-ring completion; the optional host mode waits for QMP-driven target changes.
@unsafe func checkBalloon(_ raw: UnsafeMutableRawPointer, count: Int) {
  let address = UInt(bitPattern: raw)
  unsafe validateFrameBacking(raw, count: count)
  let device = unsafe findVirtio(5)
  guard device != 0 else { finish("BALLOON_MISSING\n") }
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
  unsafe initializeVirtio(device)
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
  for _ in 0..<cycles {
    #if GUEST_HOST_BALLOON
      emit("HOST_READY\n")
      unsafe waitBalloonTarget(device, pages: 4)
    #endif
    // Virtio permits voluntary supply when requested >= actual (both initially zero).
    // Do not access donated pages from publication through deflate acknowledgement.
    _ = unsafe postVirtioBuffer(
      device, queue: 0, ring: ring, buffer: ring + 256, length: 16, deviceWrites: false,
      sequence: &inflate, timeoutMarker: "BALLOON_INFLATE_TIMEOUT\n")
    for index in 0..<4 {
      guard
        unsafe mmioWord(ring + 256 + UInt(index * 4)).load()
          == UInt32(donated.firstFrame) + UInt32(index)
      else { finish("BALLOON_LIST_FAIL\n") }
    }
    unsafe mmioWord(device + 0x104).store(4)
    guest_device_barrier()
    #if GUEST_HOST_BALLOON
      emit("HOST_INFLATED\n")
      unsafe waitBalloonTarget(device, pages: 0)
    #else
      emit("BALLOON_INFLATED\n")
    #endif
    guard unsafe mmioWord(device + 0x100).load() == 0 else { finish("BALLOON_TARGET_FAIL\n") }
    #if GUEST_BALLOON_NO_DEFLATE
      _ = unsafe postVirtioBuffer(
        device, queue: 1, ring: ring + 4096, buffer: ring + 256, length: 16,
        deviceWrites: false, sequence: &deflate, publish: false,
        timeoutMarker: "BALLOON_DEFLATE_TIMEOUT\n")
      finish("BALLOON_NEGATIVE_BYPASSED\n")
    #else
      _ = unsafe postVirtioBuffer(
        device, queue: 1, ring: ring + 4096, buffer: ring + 256, length: 16, deviceWrites: false,
        sequence: &deflate, timeoutMarker: "BALLOON_DEFLATE_TIMEOUT\n")
      unsafe mmioWord(device + 0x104).store(0)
      guest_device_barrier()
      // Deflated memory is uninitialized: reinitialize before any CPU read or allocator reuse.
      _ = unsafe guestMemoryFill(UnsafeMutableRawPointer(bitPattern: pages), 0x35, 4 * 4096)
      for index in 0..<(4 * 4096) {
        let value = unsafe VolatileMappedRegister<UInt8>(unsafeBitPattern: pages + UInt(index))
          .load()
        if value != 0x35 { finish("BALLOON_REUSE_FAIL\n") }
      }
      #if GUEST_HOST_BALLOON
        emit("HOST_DEFLATED\n")
      #endif
    #endif
  }
  unsafe resetVirtio(device)
  guard case .released = ledger.release(donated), case .released = ledger.release(rings),
    ledger.availableCount == count
  else { finish("BALLOON_RELEASE_FAIL\n") }
  emit("BALLOON_PASS\n")
}
