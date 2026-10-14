import GuestABI
import _Volatile

// Modern virtio-mmio, coherent QEMU RAM, one outstanding descriptor; no host hardware access.
@unsafe func checkDMA(_ raw: UnsafeMutableRawPointer, count: Int) {
  let address = UInt(bitPattern: raw)
  unsafe validateFrameBacking(raw, count: count)
  let device = unsafe findVirtio(4)
  guard device != 0 else { finish("DMA_MISSING\n") }
  var metadata: InlineArray<17, UInt64> = .init(repeating: 0)
  guard var ledger = FrameLedger(metadata: metadata.mutableSpan, firstFrame: address / 4096),
    case .reserved(let owned) = ledger.reserve(frameCount: 2)
  else { finish("DMA_CAPACITY_FAIL\n") }
  let ring = owned.firstFrame * 4096
  let payload = ring + 4096
  _ = unsafe guestMemoryFill(raw, 0x47, UInt(count * 4096))
  _ = unsafe guestMemoryFill(UnsafeMutableRawPointer(bitPattern: ring), 0, 4096)
  unsafe initializeVirtio(device)
  unsafe prepareVirtioQueue(device, index: 0, ring: ring)
  unsafe mmioWord(device + 0x70).store(15)
  #if GUEST_DMA_NO_PUBLISH || GUEST_DMA_UNPUBLISHED_INDEX
    let publish = false
  #else
    let publish = true
  #endif
  guard var sequence = SplitRingSequence(queueSize: 8) else { finish("VIRTIO_SEQUENCE_FAIL\n") }
  #if GUEST_RING_WRAP || GUEST_WRAP_WRONG_ID || GUEST_WRAP_WRONG_LENGTH || GUEST_WRAP_STALE || GUEST_WRAP_USED_INDEX
    let submissions = 65540
  #else
    let submissions = 1
  #endif
  let frequency = guest_timer_frequency()
  guard frequency >= 1000, frequency <= 10_000_000_000 else { finish("VIRTIO_CLOCK_FAIL\n") }
  let (deadline, overflow) = guest_timer_counter().addingReportingOverflow(frequency * 60)
  guard !overflow else { finish("VIRTIO_CLOCK_FAIL\n") }
  var largestWritten: UInt32 = 0
  for _ in 0..<submissions {
    guard guest_timer_counter() < deadline else { finish("DMA_WRAP_TIMEOUT\n") }
    #if GUEST_WRAP_STALE
      if sequence.completedCount == 65536 {
        emit("WRAP_INJECT_STALE_65536\n")
        unsafe mmioHalf(ring + 162).store(65535)
      }
    #endif
    let written = unsafe postVirtioBuffer(
      device, queue: 0, ring: ring, buffer: payload, length: 32, deviceWrites: true,
      sequence: &sequence, publish: publish)
    largestWritten = max(largestWritten, written)
  }
  guard sequence.completedCount == UInt64(submissions),
    sequence.wireIndex == UInt16(truncatingIfNeeded: submissions)
  else { finish("DMA_WRAP_COUNT_FAIL\n") }
  // Reset/acknowledge the device before returning any memory to the frame ledger.
  unsafe resetVirtio(device)
  for offset in 0..<(count * 4096) {
    let current = address + UInt(offset)
    if (ring..<(ring + 4096)).contains(current)
      || (payload..<(payload + UInt(largestWritten))).contains(current)
    {
      continue
    }
    let value = unsafe VolatileMappedRegister<UInt8>(unsafeBitPattern: current)
    if value.load() != 0x47 { finish("DMA_BOUNDS_FAIL\n") }
  }
  guard case .released = ledger.release(owned), ledger.availableCount == count else {
    finish("DMA_RELEASE_FAIL\n")
  }
  #if GUEST_RING_WRAP
    emit("DMA_WRAP_PASS 65540\n")
  #endif
  emit("DMA_PASS\n")
}
