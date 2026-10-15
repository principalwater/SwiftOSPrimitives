import BoundedMemory
func accept(_ state: inout BalloonController, sample: BalloonController.Observation) {
  do { _ = try state.observe(sample, nowNanoseconds: sample.capturedAtNanoseconds) }
  catch { state.retire() }
}
