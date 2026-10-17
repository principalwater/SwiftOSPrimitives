import Testing

@testable import NativeLinuxVMM

@Test func nativeApplicationUsesHostRelativeNanosecondsAndRejectsFutureOrigin() throws {
  let origin = ContinuousClock.now
  let application = NativeBalloonApplication(
    generation: 2, owner: 1, epoch: 2, targetBytes: 0,
    previousTargetBytes: 128 << 20, previousOwnedBytes: 64 << 20,
    previousActualBytes: 64 << 20, appliedAt: origin.advanced(by: .microseconds(1500)))
  #expect(try application.record(since: origin)["appliedSinceControlStartNanoseconds"] == 1_500_000)
  #expect(throws: NativeControlFailure.invariant) {
    try application.record(since: origin.advanced(by: .milliseconds(2)))
  }
}
