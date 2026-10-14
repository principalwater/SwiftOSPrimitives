import BoundedMemory
func frameDoubleRelease() {
  var metadata: InlineArray<5, UInt64> = .init(repeating: 0)
  guard var ledger = FrameLedger(metadata: metadata.mutableSpan),
    case .reserved(let first) = ledger.reserve(frameCount: 1)
  else { return }
  _ = ledger.release(consume first)
  _ = ledger.release(consume first)
}
