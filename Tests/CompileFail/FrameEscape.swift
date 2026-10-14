import BoundedMemory
func frameEscape() {
  var saved: FrameAllocation = .refused(.invalidSize)
  do {
    var metadata: InlineArray<5, UInt64> = .init(repeating: 0)
    guard var ledger = FrameLedger(metadata: metadata.mutableSpan) else { return }
    saved = ledger.reserve(frameCount: 1)
  }
  _ = consume saved
}
