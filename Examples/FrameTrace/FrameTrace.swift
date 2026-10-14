@c(frame_trace)
@inline(never)
@unsafe public func frameTrace(
  _ metadata: UnsafeMutablePointer<UInt64>?, _ count: Int, _ iterations: Int, _ base: UInt
) -> UInt64 {
  guard let metadata = unsafe metadata, count >= 33, count <= 129,
    iterations > 0, iterations <= 1_000_000
  else { return 0 }
  let loan = unsafe MutableSpan(_unsafeStart: metadata, count: count)
  guard var ledger = FrameLedger(metadata: consume loan, firstFrame: base) else { return 0 }
  var checksum: UInt64 = 0
  for iteration in 0..<iterations {
    let firstCount = 1 + iteration % 7
    let secondCount = 1 + iteration % 3
    guard case .reserved(let first) = ledger.reserve(frameCount: firstCount, alignment: 8),
      case .reserved(let second) = ledger.reserve(frameCount: secondCount, alignment: 2)
    else { return 0 }
    let secondFrame = second.firstFrame
    guard first.firstFrame % 8 == 0, secondFrame % 2 == 0,
      ledger.availableCount == ledger.capacity - firstCount - secondCount,
      case .released = ledger.release(consume second),
      case .reserved(let replacement) = ledger.reserve(frameCount: secondCount, alignment: 2)
    else { return 0 }
    guard replacement.firstFrame == secondFrame else { return 0 }
    // The trace digest is deliberately modular; allocator geometry/generation arithmetic is checked.
    checksum &+= UInt64(first.firstFrame) &+ UInt64(secondFrame) &+ UInt64(iteration)
    guard case .released = ledger.release(consume first),
      case .released = ledger.release(consume replacement),
      ledger.availableCount == ledger.capacity
    else { return 0 }
  }
  return checksum
}
