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
  let frequency = guest_timer_frequency()
  guard frequency >= 1000, frequency <= 10_000_000_000 else { finish("VIRTIO_CLOCK_FAIL\n") }
  let (deadline, overflow) = guest_timer_counter().addingReportingOverflow(frequency / 10)
  guard !overflow else { finish("VIRTIO_CLOCK_FAIL\n") }
  while unsafe mmioWord(device + 0x70).load() != 0 && guest_timer_counter() < deadline {}
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
// A ring uses230 bytes inside a live, zeroed4KiB frame; one descriptor outstanding at a time.
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
  unsafe mmioHalf(ring + 130).store(0)
  // Poison unused device-owned entries before QueueReady; completion must overwrite identity.
  for slot in 0..<8 {
    unsafe mmioWord(ring + 164 + UInt(slot * 8)).store(UInt32.max)
    unsafe mmioWord(ring + 168 + UInt(slot * 8)).store(UInt32.max)
  }
  guest_device_barrier()
  unsafe mmioWord(device + 0x44).store(1)
}
@unsafe func postVirtioBuffer(
  _ device: UInt, queue: UInt32, ring: UInt, buffer: UInt, length: UInt32,
  deviceWrites: Bool, sequence: inout SplitRingSequence, publish: Bool = true,
  timeoutMarker: StaticString = "DMA_TIMEOUT\n"
) -> UInt32 {
  guard sequence.queueSize == 8, !sequence.isExhausted else { finish("VIRTIO_SEQUENCE_FAIL\n") }
  let wireIndex = sequence.wireIndex
  guard unsafe mmioHalf(ring + 162).load() == wireIndex,
    unsafe mmioHalf(ring + 130).load() == wireIndex
  else { finish("VIRTIO_STALE_COMPLETION\n") }
  let slot = UInt(sequence.ringSlot)
  // A changed head on each lap makes a stale entry at a reused ring slot detectable.
  let head = UInt(sequence.descriptorHead)
  #if GUEST_WRAP_WRONG_ID || GUEST_BALLOON_WRAP_INFLATE_ID || GUEST_BALLOON_WRAP_DEFLATE_ID
    let previousID = unsafe mmioWord(ring + 164 + slot * 8).load()
  #endif
  let descriptor = ring + head * 16
  let next = wireIndex &+ 1
  let start = guest_timer_counter()
  let frequency = guest_timer_frequency()
  guard frequency >= 1000 && frequency <= 10_000_000_000 else { finish("VIRTIO_CLOCK_FAIL\n") }
  let (deadline, overflow) = start.addingReportingOverflow(frequency / 10)
  guard !overflow else { finish("VIRTIO_CLOCK_FAIL\n") }
  unsafe VolatileMappedRegister<UInt64>(unsafeBitPattern: descriptor).store(UInt64(buffer))
  unsafe mmioWord(descriptor + 8).store(length)
  unsafe mmioHalf(descriptor + 12).store(deviceWrites ? 2 : 0)
  unsafe mmioHalf(descriptor + 14).store(0)
  unsafe mmioHalf(ring + 132 + slot * 2).store(UInt16(head))
  guest_device_barrier()
  if publish {
    unsafe mmioHalf(ring + 130).store(next)
    guest_device_barrier()
    unsafe mmioWord(device + 0x50).store(queue)
  }
  #if GUEST_DMA_UNPUBLISHED_INDEX
    if !publish {
      emit("DMA_UNPUBLISHED_INDEX_INJECT\n")
      unsafe mmioHalf(ring + 162).store(next &+ 1)
    }
  #endif
  while unsafe mmioHalf(ring + 162).load() == wireIndex && guest_timer_counter() < deadline {}
  let completed = unsafe mmioHalf(ring + 162).load()
  guest_device_barrier()
  guard completed != wireIndex else { finish(timeoutMarker) }
  guard completed == next else { finish("VIRTIO_USED_INDEX_FAIL\n") }
  #if GUEST_WRAP_USED_INDEX || GUEST_WRAP_INDEX_NO_COMPLETION
    if deviceWrites && sequence.completedCount == 65536 {
      // Inject only after actual completion; a missing device reply must stay a timeout.
      emit("WRAP_INJECT_INDEX_65536\n")
      unsafe mmioHalf(ring + 162).store(next &+ 1)
      let corruptedIndex = unsafe mmioHalf(ring + 162).load()
      guest_device_barrier()
      guard corruptedIndex == next else { finish("VIRTIO_USED_INDEX_FAIL\n") }
    }
  #endif
  #if GUEST_WRONG_ID
    if queue == 0 && !deviceWrites {
      unsafe mmioWord(ring + 164 + slot * 8).store(UInt32((head + 1) % 8))
    }
  #endif
  #if GUEST_WRAP_WRONG_ID
    if deviceWrites && sequence.completedCount == 65536 {
      emit("WRAP_INJECT_ID_65536\n")
      guard previousID < 8 else { finish("VIRTIO_REPLAY_CONTROL_FAIL\n") }
      unsafe mmioWord(ring + 164 + slot * 8).store(previousID)
    }
  #elseif GUEST_WRAP_WRONG_LENGTH
    if deviceWrites && sequence.completedCount == 65536 {
      emit("WRAP_INJECT_LENGTH_65536\n")
      unsafe mmioWord(ring + 168 + slot * 8).store(length + 1)
    }
  #endif
  #if GUEST_BALLOON_WRAP_INFLATE_ID || GUEST_BALLOON_WRAP_DEFLATE_ID
    if !deviceWrites && sequence.completedCount == 65536 {
      #if GUEST_BALLOON_WRAP_INFLATE_ID
        let selectedQueue: UInt32 = 0
      #else
        let selectedQueue: UInt32 = 1
      #endif
      if queue == selectedQueue {
        emit("BALLOON_INJECT_ID_65536\n")
        guard previousID < 8 else { finish("VIRTIO_REPLAY_CONTROL_FAIL\n") }
        unsafe mmioWord(ring + 164 + slot * 8).store(previousID)
      }
    }
  #elseif GUEST_BALLOON_WRAP_LENGTH
    if !deviceWrites && queue == 1 && sequence.completedCount == 65536 {
      emit("BALLOON_INJECT_LENGTH_65536\n")
      unsafe mmioWord(ring + 168 + slot * 8).store(1)
    }
  #endif
  guard unsafe mmioWord(ring + 164 + slot * 8).load() == UInt32(head) else {
    finish("VIRTIO_IDENTITY_FAIL\n")
  }
  let written = unsafe mmioWord(ring + 168 + slot * 8).load()
  guard deviceWrites ? written > 0 && written <= length : written == 0 else {
    finish("VIRTIO_LENGTH_FAIL\n")
  }
  guard sequence.advance() else { finish("VIRTIO_SEQUENCE_FAIL\n") }
  return written
}
