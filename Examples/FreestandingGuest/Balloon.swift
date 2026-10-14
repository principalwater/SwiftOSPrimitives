import GuestABI
import _Volatile

// One real guest-initiated inflate/deflate round trip, not a host target controller.
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
  // Virtio permits voluntary supply when requested >= actual (both initially zero).
  // Do not access donated pages from publication through deflate acknowledgement.
  _ = unsafe postVirtioBuffer(
    device, queue: 0, ring: ring, buffer: ring + 256, length: 16, deviceWrites: false,
    timeoutMarker: "BALLOON_INFLATE_TIMEOUT\n")
  unsafe mmioWord(device + 0x104).store(4)
  guest_device_barrier()
  emit("BALLOON_INFLATED\n")
  guard unsafe mmioWord(device + 0x100).load() == 0 else { finish("BALLOON_TARGET_FAIL\n") }
  #if GUEST_BALLOON_NO_DEFLATE
    _ = unsafe postVirtioBuffer(
      device, queue: 1, ring: ring + 4096, buffer: ring + 256, length: 16,
      deviceWrites: false, publish: false, timeoutMarker: "BALLOON_DEFLATE_TIMEOUT\n")
    finish("BALLOON_NEGATIVE_BYPASSED\n")
  #else
    _ = unsafe postVirtioBuffer(
      device, queue: 1, ring: ring + 4096, buffer: ring + 256, length: 16, deviceWrites: false,
      timeoutMarker: "BALLOON_DEFLATE_TIMEOUT\n")
    unsafe mmioWord(device + 0x104).store(0)
    guest_device_barrier()
    // Deflated memory is uninitialized: reinitialize before any CPU read or allocator reuse.
    _ = unsafe guestMemoryFill(UnsafeMutableRawPointer(bitPattern: pages), 0x35, 4 * 4096)
    for index in 0..<(4 * 4096) {
      let value = unsafe VolatileMappedRegister<UInt8>(unsafeBitPattern: pages + UInt(index)).load()
      if value != 0x35 { finish("BALLOON_REUSE_FAIL\n") }
    }
    unsafe resetVirtio(device)
    guard case .released = ledger.release(donated), case .released = ledger.release(rings),
      ledger.availableCount == count
    else { finish("BALLOON_RELEASE_FAIL\n") }
    emit("BALLOON_PASS\n")
  #endif
}
