import GuestABI
import _Volatile

// Unsafe wire boundary for pinned QEMU virt-10.2; callers retain exclusively owned guest RAM.
@unsafe func mmioWord(_ address: UInt) -> VolatileMappedRegister<UInt32> {
  unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: address)
}
@unsafe func mmioHalf(_ address: UInt) -> VolatileMappedRegister<UInt16> {
  unsafe VolatileMappedRegister<UInt16>(unsafeBitPattern: address)
}
@unsafe func findVirtio(_ identifier: UInt32) -> UInt {
  var device: UInt = 0
  for slot in 0..<32 {
    let base = 0x0a00_0000 + UInt(slot * 512)
    if unsafe mmioWord(base).load() == 0x7472_6976 && mmioWord(base + 8).load() == identifier {
      if device != 0 { finish("VIRTIO_AMBIGUOUS\n") }
      device = base
    }
  }
  return device
}
@unsafe func resetVirtio(_ device: UInt) {
  unsafe mmioWord(device + 0x70).store(0)
  guest_device_barrier()
  guard unsafe mmioWord(device + 0x70).load() == 0 else { finish("VIRTIO_RESET_FAIL\n") }
}
@unsafe func initializeVirtio(_ device: UInt) {
  guard unsafe mmioWord(device + 4).load() == 2 else { finish("VIRTIO_VERSION_FAIL\n") }
  unsafe resetVirtio(device)
  unsafe mmioWord(device + 0x70).store(3)
  unsafe mmioWord(device + 0x14).store(1)
  guard unsafe mmioWord(device + 0x10).load() & 1 != 0 else { finish("VIRTIO_FEATURE_FAIL\n") }
  unsafe mmioWord(device + 0x24).store(1)
  unsafe mmioWord(device + 0x20).store(1)
  unsafe mmioWord(device + 0x24).store(0)
  unsafe mmioWord(device + 0x20).store(0)
  unsafe mmioWord(device + 0x70).store(11)
  guard unsafe mmioWord(device + 0x70).load() == 11 else { finish("VIRTIO_FEATURE_FAIL\n") }
}
// A ring uses 230 bytes inside a live, zeroed 4KiB frame. Each queue posts once in this fixture.
@unsafe func prepareVirtioQueue(_ device: UInt, index: UInt32, ring: UInt) {
  unsafe mmioWord(device + 0x30).store(index)
  guard unsafe mmioWord(device + 0x34).load() >= 8 && mmioWord(device + 0x44).load() == 0 else {
    finish("VIRTIO_QUEUE_FAIL\n")
  }
  unsafe mmioWord(device + 0x38).store(8)
  let locations: InlineArray<3, (UInt, UInt)> = [
    (0x80, ring), (0x90, ring + 128), (0xa0, ring + 160),
  ]
  for index in 0..<3 {
    let (offset, pointer) = locations[index]
    unsafe mmioWord(device + offset).store(UInt32(truncatingIfNeeded: pointer))
    unsafe mmioWord(device + offset + 4).store(UInt32(truncatingIfNeeded: pointer >> 32))
  }
  unsafe mmioHalf(ring + 128).store(1)
  unsafe mmioHalf(ring + 132).store(0)
  guest_device_barrier()
  unsafe mmioWord(device + 0x44).store(1)
}
@unsafe func postVirtioBuffer(
  _ device: UInt, queue: UInt32, ring: UInt, buffer: UInt, length: UInt32,
  deviceWrites: Bool, publish: Bool = true, timeoutMarker: StaticString = "DMA_TIMEOUT\n"
) -> UInt32 {
  unsafe VolatileMappedRegister<UInt64>(unsafeBitPattern: ring).store(UInt64(buffer))
  unsafe mmioWord(ring + 8).store(length)
  unsafe mmioHalf(ring + 12).store(deviceWrites ? 2 : 0)
  guest_device_barrier()
  if publish {
    unsafe mmioHalf(ring + 130).store(1)
    guest_device_barrier()
    unsafe mmioWord(device + 0x50).store(queue)
  }
  let start = guest_timer_counter()
  let frequency = guest_timer_frequency()
  guard frequency >= 1000 && frequency <= 10_000_000_000 else { finish("VIRTIO_CLOCK_FAIL\n") }
  let (deadline, overflow) = start.addingReportingOverflow(frequency / 10)
  guard !overflow else { finish("VIRTIO_CLOCK_FAIL\n") }
  while unsafe mmioHalf(ring + 162).load() == 0 && guest_timer_counter() < deadline {}
  guest_device_barrier()
  guard unsafe mmioHalf(ring + 162).load() == 1, unsafe mmioWord(ring + 164).load() == 0 else {
    finish(timeoutMarker)
  }
  let written = unsafe mmioWord(ring + 168).load()
  guard deviceWrites ? written > 0 && written <= length : written == 0 else {
    finish("VIRTIO_LENGTH_FAIL\n")
  }
  return written
}
