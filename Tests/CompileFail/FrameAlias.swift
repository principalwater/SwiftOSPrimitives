import BoundedMemory
func frameAlias() {
  var metadata: InlineArray<5, UInt64> = .init(repeating: 0)
  var loan = metadata.mutableSpan
  guard var ledger = FrameLedger(metadata: loan),
    case .reserved(let first) = ledger.reserve(frameCount: 1)
  else { return }
  loan[0] = 0
  _ = ledger.release(consume first)
}
