import BoundedMemory
func framePositive() {
  var metadata: InlineArray<5, UInt64> = .init(repeating: 0)
  guard var ledger = FrameLedger(metadata: metadata.mutableSpan),
    case .reserved(let first) = ledger.reserve(frameCount: 1),
    case .reserved(let second) = ledger.reserve(frameCount: 2)
  else { return }
  _ = ledger.release(consume second)
  _ = ledger.release(consume first)
}
