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
  #if GUEST_DMA_NO_PUBLISH
    let publish = false
  #else
    let publish = true
  #endif
  let written = unsafe postVirtioBuffer(
    device, queue: 0, ring: ring, buffer: payload, length: 32, deviceWrites: true,
    publish: publish)
  // Reset/acknowledge the device before returning any memory to the frame ledger.
  unsafe resetVirtio(device)
  for offset in 0..<(count * 4096) {
    let current = address + UInt(offset)
    if (ring..<(ring + 4096)).contains(current)
      || (payload..<(payload + UInt(written))).contains(current)
    {
      continue
    }
    let value = unsafe VolatileMappedRegister<UInt8>(unsafeBitPattern: current)
    if value.load() != 0x47 { finish("DMA_BOUNDS_FAIL\n") }
  }
  guard case .released = ledger.release(owned), ledger.availableCount == count else {
    finish("DMA_RELEASE_FAIL\n")
  }
  emit("DMA_PASS\n")
}
