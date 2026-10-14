import BoundedMemory
func frameCopy() {
  var metadata: InlineArray<5, UInt64> = .init(repeating: 0)
  guard var ledger = FrameLedger(metadata: metadata.mutableSpan),
    case .reserved(let first) = ledger.reserve(frameCount: 1)
  else { return }
  let duplicate = copy first
  _ = ledger.release(consume first)
  _ = ledger.release(consume duplicate)
}
