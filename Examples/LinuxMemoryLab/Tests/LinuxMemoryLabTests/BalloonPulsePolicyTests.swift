import Testing

@testable import NativeLinuxVMM

private struct PulseFixture {
  let began = ContinuousClock.now
  let geometry: NativeMemoryGeometry
  init() throws {
    geometry = try .init(bootBytes: 512 << 20, dynamicBytes: 2560 << 20)
  }
  func time(_ milliseconds: Int64) -> ContinuousClock.Instant {
    began.advanced(by: .milliseconds(milliseconds))
  }
  func sample(_ sequence: UInt64, _ at: Int64, available: UInt64 = 2560 << 20)
    -> NativeMemoryObservation
  {
    .init(sequence: sequence, capturedAt: time(at), total: 2995 << 20, available: available)
  }
  func device(
    target: UInt64 = 0, actual: UInt64 = 0, owned: UInt64 = 0,
    epoch: UInt64 = 1, applied: Bool = true, quarantined: Bool = false
  ) -> NativeBalloonState {
    .init(
      epoch: epoch, ready: true, targetBytes: target, actualBytes: actual,
      ownedBytes: owned, quarantined: quarantined,
      requestGeneration: 1, appliedGeneration: applied ? 1 : 0, zeroTargetObserved: true)
  }
  func policy(lifetime: ContinuousClock.Instant? = nil) throws -> BalloonPulsePolicy {
    try .init(
      geometry: geometry, epoch: 1, residentTarget: 1984 << 20, now: began, lifetime: lifetime)
  }
}

@Test func pulseRestoresCapacityBeforeNewAdmission() throws {
  let f = try PulseFixture()
  var p = try f.policy()
  #expect(
    try p.observe(
      f.sample(1, 0), device: f.device(), before: f.device(), footprint: 3 << 30,
      recycled: 0, now: f.time(0)) == .wait)
  #expect(
    try p.observe(
      f.sample(2, 301), device: f.device(), before: f.device(), footprint: 3 << 30,
      recycled: 0, now: f.time(301)) == .inflate(128 << 20))
  #expect(
    try p.observe(
      f.sample(3, 350), device: f.device(applied: false), before: f.device(applied: false),
      footprint: 3 << 30,
      recycled: 0, now: f.time(350)) == .wait)
  #expect(
    try p.observe(
      f.sample(4, 400),
      device: f.device(
        target: 128 << 20,
        actual: 64 << 20, owned: 64 << 20),
      before: f.device(
        target: 128 << 20,
        actual: 64 << 20, owned: 64 << 20), footprint: 1800 << 20,
      recycled: 1 << 30, now: f.time(400)) == .zero)
  #expect(
    try p.observe(
      f.sample(5, 450), device: f.device(applied: false), before: f.device(applied: false),
      footprint: 1800 << 20,
      recycled: 1 << 30, now: f.time(450)) == .wait)
  #expect(p.completedPulses == 0)
  #expect(
    try p.observe(
      f.sample(6, 500), device: f.device(), before: f.device(), footprint: 1800 << 20,
      recycled: 1 << 30, now: f.time(500)) == .wait)
  #expect(p.completedPulses == 1 && p.lastProgressBytes == 1 << 30)
  #expect(
    try p.observe(
      f.sample(7, 800), device: f.device(), before: f.device(), footprint: 3 << 30,
      recycled: 1 << 30, now: f.time(800)) == .wait)
}

@Test func reserveRescueDrainsAndNoProgressBacksOff() throws {
  let f = try PulseFixture()
  var p = try f.policy()
  #expect(
    try p.observe(
      f.sample(1, 301), device: f.device(), before: f.device(), footprint: 3 << 30,
      recycled: 0, now: f.time(301)) == .inflate(128 << 20))
  #expect(
    try p.observe(
      f.sample(2, 400, available: 480 << 20),
      device: f.device(target: 128 << 20, actual: 64 << 20, owned: 64 << 20),
      before: f.device(target: 128 << 20, actual: 64 << 20, owned: 64 << 20), footprint: 3 << 30,
      recycled: 0, now: f.time(400)) == .zero)
  #expect(
    try p.observe(
      f.sample(3, 500), device: f.device(), before: f.device(), footprint: 3 << 30,
      recycled: 0, now: f.time(500)) == .wait)
  #expect(
    try p.observe(
      f.sample(4, 2400), device: f.device(), before: f.device(), footprint: 3 << 30,
      recycled: 0, now: f.time(2400)) == .wait)
  #expect(
    try p.observe(
      f.sample(5, 2500), device: f.device(), before: f.device(), footprint: 3 << 30,
      recycled: 0, now: f.time(2500)) == .inflate(128 << 20))
}

@Test func stopDrainUsesFirstStopInstant() throws {
  let f = try PulseFixture()
  var p = try f.policy()
  _ = try p.observe(
    f.sample(1, 301), device: f.device(), before: f.device(), footprint: 3 << 30,
    recycled: 0, now: f.time(301))
  #expect(
    try p.observe(
      f.sample(2, 7000),
      device: f.device(
        target: 128 << 20,
        actual: 64 << 20, owned: 64 << 20),
      before: f.device(
        target: 128 << 20,
        actual: 64 << 20, owned: 64 << 20), footprint: 3 << 30,
      recycled: 0, now: f.time(7000), stoppedAt: f.time(1000)) == .zero)
  #expect(throws: NativeControlFailure.drainTimedOut) {
    try p.observe(
      f.sample(3, 9000),
      device: f.device(
        target: 0, actual: 1 << 30,
        owned: 1 << 30),
      before: f.device(
        target: 0, actual: 1 << 30,
        owned: 1 << 30), footprint: 3 << 30, recycled: 0, now: f.time(9000),
      stoppedAt: f.time(1000))
  }
}

@Test func pulseLeaseCannotExtendFromLaterObservations() throws {
  let f = try PulseFixture()
  var p = try f.policy()
  _ = try p.observe(
    f.sample(1, 301), device: f.device(), before: f.device(), footprint: 3 << 30,
    recycled: 0, now: f.time(301))
  #expect(throws: NativeControlFailure.pulseTimedOut) {
    try p.observe(
      f.sample(2, 8301), device: f.device(target: 2 << 30), before: f.device(target: 2 << 30),
      footprint: 3 << 30,
      recycled: 0, now: f.time(8301))
  }
}

@Test func staleFutureAndChangedEpochCannotAuthorizePulses() throws {
  let f = try PulseFixture()
  var stale = try f.policy()
  #expect(throws: NativeControlFailure.staleObservation) {
    try stale.observe(
      f.sample(1, 0), device: f.device(), before: f.device(), footprint: 3 << 30,
      recycled: 0, now: f.time(3001))
  }
  var future = try f.policy()
  #expect(throws: NativeControlFailure.invariant) {
    try future.observe(
      f.sample(1, 500), device: f.device(), before: f.device(), footprint: 3 << 30,
      recycled: 0, now: f.time(499))
  }
  var reset = try f.policy()
  #expect(throws: NativeControlFailure.ownership) {
    try reset.observe(
      f.sample(1, 301), device: f.device(epoch: 2), before: f.device(epoch: 2), footprint: 3 << 30,
      recycled: 0, now: f.time(301))
  }
}

@Test func quietBudgetAndLifetimeRefuseUnnecessaryOrUndrainableWork() throws {
  let f = try PulseFixture()
  var p = try f.policy()
  #expect(
    try p.observe(
      f.sample(1, 301), device: f.device(), before: f.device(), footprint: 1800 << 20,
      recycled: 0, now: f.time(301)) == .wait)
  #expect(
    try p.observe(
      f.sample(2, 400, available: 600 << 20), device: f.device(), before: f.device(),
      footprint: 3 << 30, recycled: 0, now: f.time(400)) == .wait)
  var short = try f.policy(lifetime: f.time(10000))
  #expect(
    try short.observe(
      f.sample(1, 301), device: f.device(), before: f.device(), footprint: 3 << 30,
      recycled: 0, now: f.time(301)) == .wait)
  #expect(throws: NativeControlFailure.lifetimeExpired) {
    try short.observe(
      f.sample(2, 10000), device: f.device(), before: f.device(),
      footprint: 3 << 30, recycled: 0, now: f.time(10000))
  }
}

@Test(arguments: [
  (UInt64(0), UInt64(1984 << 20), UInt64(512 << 20)),
  (UInt64(1), UInt64(256 << 20), UInt64(512 << 20)),
  (UInt64(1), UInt64(1984 << 20), UInt64.max),
]) func pulseConfigurationRefusesUnboundedOrBelowBootLimits(
  _ values: (UInt64, UInt64, UInt64)
) throws {
  let f = try PulseFixture()
  #expect(throws: NativeControlFailure.arguments) {
    try BalloonPulsePolicy(
      geometry: f.geometry, epoch: values.0,
      residentTarget: values.1, reserve: values.2, now: f.began)
  }
}

@Test func settledPulseGrowsInBoundedStepsWithoutRenewingDeadline() throws {
  let f = try PulseFixture()
  var p = try f.policy()
  #expect(
    try p.observe(
      f.sample(1, 301, available: 1024 << 20), device: f.device(), before: f.device(),
      footprint: 3 << 30, recycled: 0, now: f.time(301)) == .inflate(128 << 20))
  let deadline = p.deadline
  #expect(
    try p.observe(
      f.sample(2, 400, available: 900 << 20),
      device: f.device(target: 128 << 20, actual: 128 << 20, owned: 128 << 20),
      before: f.device(target: 128 << 20, actual: 128 << 20, owned: 128 << 20),
      footprint: 3 << 30, recycled: 16 << 20, now: f.time(400)) == .inflate(256 << 20))
  #expect(p.deadline == deadline)
  #expect(
    try p.observe(
      f.sample(3, 500, available: 512 << 20),
      device: f.device(target: 256 << 20, actual: 256 << 20, owned: 256 << 20),
      before: f.device(target: 256 << 20, actual: 256 << 20, owned: 256 << 20),
      footprint: 3 << 30, recycled: 32 << 20, now: f.time(500)) == .zero)
  #expect(p.deadline == f.time(8500))
}

@Test func aReplyCapturedBeforeTheTargetChangeCannotGrowAPulse() throws {
  let f = try PulseFixture()
  var p = try f.policy()
  _ = try p.observe(
    f.sample(1, 301), device: f.device(), before: f.device(), footprint: 3 << 30,
    recycled: 0, now: f.time(301))
  #expect(throws: NativeControlFailure.invariant) {
    try p.observe(
      f.sample(2, 300), device: f.device(target: 128 << 20), before: f.device(target: 128 << 20),
      footprint: 3 << 30, recycled: 0, now: f.time(400))
  }
}

@Test func pendingPFNsCannotBeDoubleCountedWithAnEarlierAvailableSample() throws {
  let f = try PulseFixture()
  var p = try f.policy()
  _ = try p.observe(
    f.sample(1, 301, available: 1024 << 20), device: f.device(),
    before: f.device(), footprint: 3 << 30, recycled: 0, now: f.time(301))
  #expect(
    try p.observe(
      f.sample(2, 400, available: 640 << 20),
      device: f.device(target: 128 << 20, actual: 128 << 20, owned: 128 << 20),
      before: f.device(target: 128 << 20, actual: 64 << 20, owned: 64 << 20),
      footprint: 3 << 30, recycled: 16 << 20, now: f.time(400)) == .wait)
}

@Test func unreachableBalloonFloorDoesNotRepeatTheSameIdlePulse() throws {
  let f = try PulseFixture()
  var p = try f.policy()
  _ = try p.observe(
    f.sample(1, 301, available: 1024 << 20), device: f.device(),
    before: f.device(), footprint: 3 << 30, recycled: 0, now: f.time(301))
  for step in 1...4 {
    let held = UInt64(step) * (128 << 20)
    let device = f.device(target: held, actual: held, owned: held)
    _ = try p.observe(
      f.sample(
        UInt64(step + 1), Int64(400 + step * 100),
        available: (1024 << 20) - held), device: device, before: device,
      footprint: 2300 << 20, recycled: held, now: f.time(Int64(400 + step * 100)))
  }
  _ = try p.observe(
    f.sample(6, 900, available: 1024 << 20), device: f.device(),
    before: f.device(), footprint: 2300 << 20, recycled: 512 << 20, now: f.time(900))
  #expect(
    try p.observe(
      f.sample(7, 5000, available: 1024 << 20), device: f.device(),
      before: f.device(), footprint: 2300 << 20, recycled: 512 << 20, now: f.time(5000)) == .wait)
}

@Test func newGuestHeadroomReopensAnUnreachableFloor() throws {
  let f = try PulseFixture()
  var p = try f.policy()
  _ = try p.observe(
    f.sample(1, 301, available: 640 << 20), device: f.device(),
    before: f.device(), footprint: 3 << 30, recycled: 0, now: f.time(301))
  let held = f.device(target: 128 << 20, actual: 128 << 20, owned: 128 << 20)
  #expect(
    try p.observe(
      f.sample(2, 400, available: 512 << 20), device: held, before: held,
      footprint: 3 << 30, recycled: 64 << 20, now: f.time(400)) == .zero)
  _ = try p.observe(
    f.sample(3, 500, available: 640 << 20), device: f.device(),
    before: f.device(), footprint: 3 << 30, recycled: 64 << 20, now: f.time(500))
  #expect(
    try p.observe(
      f.sample(4, 2000, available: 640 << 20), device: f.device(),
      before: f.device(), footprint: 3 << 30, recycled: 64 << 20, now: f.time(2000)) == .wait)
  #expect(
    try p.observe(
      f.sample(5, 3000, available: 800 << 20), device: f.device(),
      before: f.device(), footprint: 3 << 30, recycled: 64 << 20, now: f.time(3000))
      == .inflate(128 << 20))
}

@Test func aFloorWaitsForAnObservationAfterAllDeflatesHaveSettled() throws {
  let f = try PulseFixture()
  var p = try f.policy()
  _ = try p.observe(
    f.sample(1, 301, available: 640 << 20), device: f.device(),
    before: f.device(), footprint: 3 << 30, recycled: 0, now: f.time(301))
  let held = f.device(target: 128 << 20, actual: 128 << 20, owned: 128 << 20)
  _ = try p.observe(
    f.sample(2, 400, available: 512 << 20), device: held, before: held,
    footprint: 3 << 30, recycled: 64 << 20, now: f.time(400))
  let pending = f.device(target: 0, actual: 128 << 20, owned: 128 << 20)
  _ = try p.observe(
    f.sample(3, 500, available: 512 << 20), device: f.device(), before: pending,
    footprint: 3 << 30, recycled: 64 << 20, now: f.time(500))
  #expect(p.completedPulses == 0)
  _ = try p.observe(
    f.sample(4, 600, available: 640 << 20), device: f.device(), before: f.device(),
    footprint: 3 << 30, recycled: 64 << 20, now: f.time(600))
  #expect(
    try p.observe(
      f.sample(5, 3000, available: 640 << 20), device: f.device(),
      before: f.device(), footprint: 3 << 30, recycled: 64 << 20, now: f.time(3000)) == .wait)
}

@Test func aHeadroomClampCannotCauseTheSamePartialIdlePulseAgain() throws {
  let f = try PulseFixture()
  var p = try f.policy()
  _ = try p.observe(
    f.sample(1, 301, available: 768 << 20), device: f.device(),
    before: f.device(), footprint: 3 << 30, recycled: 0, now: f.time(301))
  let first = f.device(target: 128 << 20, actual: 128 << 20, owned: 128 << 20)
  _ = try p.observe(
    f.sample(2, 400, available: 640 << 20), device: first, before: first,
    footprint: 3 << 30, recycled: 64 << 20, now: f.time(400))
  let partial = f.device(target: 256 << 20, actual: 200 << 20, owned: 200 << 20)
  let before = f.device(target: 256 << 20, actual: 160 << 20, owned: 160 << 20)
  #expect(
    try p.observe(
      f.sample(3, 500, available: 568 << 20), device: partial, before: before,
      footprint: 3 << 30, recycled: 64 << 20, now: f.time(500)) == .zero)
  _ = try p.observe(
    f.sample(4, 600, available: 768 << 20), device: f.device(), before: f.device(),
    footprint: 3 << 30, recycled: 64 << 20, now: f.time(600))
  #expect(
    try p.observe(
      f.sample(5, 3000, available: 768 << 20), device: f.device(),
      before: f.device(), footprint: 3 << 30, recycled: 64 << 20, now: f.time(3000)) == .wait)
}

@Test func aSlowPartialPulseStartsRescueBeforeTheNativeLeaseExpires() throws {
  let f = try PulseFixture()
  var p = try f.policy()
  _ = try p.observe(
    f.sample(1, 301), device: f.device(), before: f.device(), footprint: 3 << 30,
    recycled: 0, now: f.time(301))
  let held = f.device(target: 128 << 20, actual: 64 << 20, owned: 64 << 20)
  #expect(
    try p.observe(
      f.sample(2, 4301), device: held, before: held, footprint: 3 << 30,
      recycled: 0, now: f.time(4301)) == .zero)
}

@Test func newWorkDoesNotWaitForAnObsoleteLongBackoff() throws {
  let f = try PulseFixture()
  var p = try f.policy()
  var sequence: UInt64 = 0
  for issued in [Int64(301), 2501, 6701] {
    sequence += 1
    _ = try p.observe(
      f.sample(sequence, issued), device: f.device(), before: f.device(),
      footprint: 3 << 30, recycled: 0, now: f.time(issued))
    let held = f.device(target: 128 << 20, actual: 64 << 20, owned: 64 << 20)
    sequence += 1
    _ = try p.observe(
      f.sample(sequence, issued + 100, available: 480 << 20),
      device: held, before: held, footprint: 3 << 30, recycled: 0, now: f.time(issued + 100))
    sequence += 1
    _ = try p.observe(
      f.sample(sequence, issued + 200), device: f.device(), before: f.device(),
      footprint: 3 << 30, recycled: 0, now: f.time(issued + 200))
  }
  sequence += 1
  _ = try p.observe(
    f.sample(sequence, 7400), device: f.device(), before: f.device(),
    footprint: (3 << 30) + (256 << 20), recycled: 0, now: f.time(7400))
  sequence += 1
  #expect(
    try p.observe(
      f.sample(sequence, 7800), device: f.device(), before: f.device(),
      footprint: (3 << 30) + (256 << 20), recycled: 0, now: f.time(7800)) == .inflate(128 << 20))
}

@Test func newlyFreedHeadroomCanExtendASettledPulseWithoutRenewingItsLease() throws {
  let f = try PulseFixture()
  var p = try f.policy()
  _ = try p.observe(
    f.sample(1, 301, available: 768 << 20), device: f.device(), before: f.device(),
    footprint: 3 << 30, recycled: 0, now: f.time(301))
  let deadline = p.deadline
  for step in 1...3 {
    let held = UInt64(step) * (128 << 20)
    let at = Int64(400 + step * 100)
    let device = f.device(target: held, actual: held, owned: held)
    #expect(
      try p.observe(
        f.sample(UInt64(step + 1), at, available: (2560 << 20) - held),
        device: device, before: device, footprint: 3 << 30, recycled: held,
        now: f.time(at)) == .inflate(held + (128 << 20)))
    #expect(p.deadline == deadline)
  }
}

@Test func newlyFreedHeadroomCannotGrowAPulseAcrossUnsettledOwnership() throws {
  let f = try PulseFixture()
  var p = try f.policy()
  _ = try p.observe(
    f.sample(1, 301, available: 768 << 20), device: f.device(), before: f.device(),
    footprint: 3 << 30, recycled: 0, now: f.time(301))
  let partial = f.device(target: 128 << 20, actual: 64 << 20, owned: 64 << 20)
  let held = f.device(target: 128 << 20, actual: 128 << 20, owned: 128 << 20)
  #expect(
    try p.observe(
      f.sample(2, 400, available: 2400 << 20), device: held, before: partial,
      footprint: 3 << 30, recycled: 64 << 20, now: f.time(400)) == .wait)
  #expect(
    try p.observe(
      f.sample(3, 500, available: 512 << 20), device: held, before: held,
      footprint: 3 << 30, recycled: 128 << 20, now: f.time(500)) == .zero)
}

@Test func refreshedHeadroomStillHonorsTheAbsolutePulseCapacity() throws {
  let f = try PulseFixture()
  var p = try f.policy()
  _ = try p.observe(
    f.sample(1, 301, available: 768 << 20), device: f.device(), before: f.device(),
    footprint: 3 << 30, recycled: 0, now: f.time(301))
  let deadline = p.deadline
  for step in 1...16 {
    let held = UInt64(step) * (128 << 20)
    let at = Int64(400 + step * 100)
    let device = f.device(target: held, actual: held, owned: held)
    let expected: BalloonPulsePolicy.Action = step == 16 ? .zero : .inflate(held + (128 << 20))
    #expect(
      try p.observe(
        f.sample(UInt64(step + 1), at, available: (2995 << 20) - held),
        device: device, before: device, footprint: 3 << 30, recycled: held,
        now: f.time(at)) == expected)
    if step < 16 { #expect(p.deadline == deadline) }
  }
}

@Test func aStaleCeilingCannotEndAPulseWhoseSampleShowsFreshHeadroom() throws {
  let f = try PulseFixture()
  var p = try f.policy()
  _ = try p.observe(
    f.sample(1, 301, available: 640 << 20), device: f.device(), before: f.device(),
    footprint: 3 << 30, recycled: 0, now: f.time(301))
  let held = f.device(target: 128 << 20, actual: 128 << 20, owned: 128 << 20)
  #expect(
    try p.observe(
      f.sample(2, 400, available: 1664 << 20), device: held,
      before: f.device(target: 128 << 20, applied: false),
      footprint: 3 << 30, recycled: 64 << 20, now: f.time(400)) == .wait)
  #expect(
    try p.observe(
      f.sample(3, 500, available: 1664 << 20), device: held, before: held,
      footprint: 3 << 30, recycled: 128 << 20, now: f.time(500)) == .inflate(256 << 20))
}
