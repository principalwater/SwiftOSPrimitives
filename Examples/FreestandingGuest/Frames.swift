import _Volatile

// The linker owns sixteen aligned 4KiB frames plus canary padding, not MMU guard pages.
@unsafe func checkFrames(_ raw: UnsafeMutableRawPointer, count: Int) {
  let pageSize = 4096
  let address = UInt(bitPattern: raw)
  guard count == 16, address % UInt(pageSize) == 0,
    address >= 0x4008_0000 + UInt(pageSize),
    address <= 0x4400_0000 - UInt((count + 1) * pageSize)
  else { finish("BAD_FRAME_EXTENT\n") }
  let baseFrame = address / UInt(pageSize)
  _ = unsafe raw.advanced(by: -pageSize).initializeMemory(
    as: UInt8.self, repeating: 71, count: pageSize)
  _ = unsafe raw.advanced(by: count * pageSize).initializeMemory(
    as: UInt8.self, repeating: 71, count: pageSize)
  let bytes = unsafe raw.initializeMemory(as: UInt8.self, repeating: 71, count: count * pageSize)
  var metadata: InlineArray<17, UInt64> = .init(repeating: 0)
  guard var ledger = FrameLedger(metadata: metadata.mutableSpan, firstFrame: baseFrame) else {
    finish("FRAME_INIT_FAIL\n")
  }
  for _ in 0..<100 {
    _ = unsafe guestMemoryFill(raw, 71, UInt(count * pageSize))
    guard case .reserved(let first) = ledger.reserve(frameCount: 4, alignment: 4),
      case .reserved(let second) = ledger.reserve(frameCount: 2)
    else { finish("FRAME_CAPACITY_FAIL\n") }
    guard first.firstFrame >= baseFrame, second.firstFrame >= baseFrame,
      first.firstFrame - baseFrame <= UInt(count - 4),
      second.firstFrame - baseFrame <= UInt(count - 2),
      first.frameCount == 4, second.frameCount == 2, first.firstFrame % 4 == 0
    else { finish("FRAME_BOUNDS_FAIL\n") }
    let firstOffset = Int(first.firstFrame - baseFrame)
    let secondOffset = Int(second.firstFrame - baseFrame)
    guard
      !((firstOffset..<(firstOffset + 4)).overlaps(secondOffset..<(secondOffset + 2)))
    else { finish("FRAME_BOUNDS_FAIL\n") }
    _ = unsafe guestMemoryFill(raw.advanced(by: firstOffset * pageSize), 0x35, UInt(4 * pageSize))
    _ = unsafe guestMemoryFill(raw.advanced(by: secondOffset * pageSize), 0x7f, UInt(2 * pageSize))
    guard case .released = ledger.release(consume second),
      case .reserved(let replacement) = ledger.reserve(frameCount: 2),
      replacement.firstFrame == baseFrame + UInt(secondOffset)
    else { finish("FRAME_REUSE_FAIL\n") }
    _ = unsafe guestMemoryFill(raw.advanced(by: secondOffset * pageSize), 0, UInt(2 * pageSize))
    for index in 0..<(count * pageSize) {
      let frame = index / pageSize
      let expected: UInt8 =
        (firstOffset..<(firstOffset + 4)).contains(frame)
        ? 0x35
        : (secondOffset..<(secondOffset + 2)).contains(frame) ? 0 : 71
      if unsafe bytes[index] != expected { finish("FRAME_DATA_FAIL\n") }
    }
    guard case .released = ledger.release(consume first),
      case .released = ledger.release(consume replacement), ledger.availableCount == count
    else { finish("FRAME_RELEASE_FAIL\n") }
  }
  guard case .reserved(let whole) = ledger.reserve(frameCount: count),
    whole.firstFrame == baseFrame,
    case .released = ledger.release(consume whole)
  else { finish("FRAME_CAPACITY_LEAK\n") }
  #if GUEST_FRAME_FAILURE
    unsafe VolatileMappedRegister<UInt8>(
      unsafeBitPattern: address + UInt((count + 1) * pageSize) - 1
    ).store(0)
  #endif
  for index in 0..<pageSize {
    let before = unsafe VolatileMappedRegister<UInt8>(
      unsafeBitPattern: address - UInt(pageSize) + UInt(index))
    let after = unsafe VolatileMappedRegister<UInt8>(
      unsafeBitPattern: address + UInt(count * pageSize + index))
    if before.load() != 71 || after.load() != 71 { finish("FRAME_FAIL\n") }
  }
}
