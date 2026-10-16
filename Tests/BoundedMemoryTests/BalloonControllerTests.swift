import BoundedMemory
import Testing

private let page: UInt64 = 4096
private func controller() -> BalloonController {
  guard
    let budget = BalloonBudget(
      installedBytes: 64 * page, minimumResidentBytes: 16 * page, granuleBytes: page,
      maximumStepBytes: 8 * page),
    let state = BalloonController(
      budget: budget, epoch: 73, guestReserveBytes: 8 * page, hysteresisBytes: 4 * page,
      maximumObservationAgeNanoseconds: 100, cooldownNanoseconds: 100,
      completionTimeoutNanoseconds: 1000)
  else { preconditionFailure("Invalid test geometry") }
  return state
}
private func sample(
  _ sequence: UInt64, at: UInt64 = 1, actual: UInt64 = 64 * page,
  requested: UInt64? = nil, available: UInt64 = 24 * page,
  cap: UInt64 = 64 * page, epoch: UInt64 = 73,
  hostPressure: Bool = false, guestPressure: Bool = false
) -> BalloonController.Observation {
  .init(
    epoch: epoch, sequence: sequence, capturedAtNanoseconds: at,
    actualResidentBytes: actual, requestedResidentBytes: requested ?? actual,
    guestAvailableBytes: available, hostResidentLimitBytes: cap,
    hostUnderPressure: hostPressure, guestUnderPressure: guestPressure)
}
private func request(_ value: BalloonController.Request?) throws -> BalloonController.Request {
  try #require(value)
}
private func check(
  _ state: borrowing BalloonController, pending: BalloonController.Request?,
  reason: BalloonController.Failure? = nil
) {
  let saved = state.pendingRequest
  let retired = state.retirementReason
  #expect(saved == pending)
  #expect(retired == reason)
}
struct BalloonControllerTests {
  @Test func setterDeliveryAndPreSendFenceAreRequired() throws {
    var state = controller()
    let first = try request(state.observe(sample(1), nowNanoseconds: 1))
    #expect(first.targetResidentBytes == 56 * page)
    _ = try state.observe(sample(2, at: 2, actual: 56 * page), nowNanoseconds: 2)
    check(state, pending: first)
    try state.didApply(first, afterObservationSequence: 3, atNanoseconds: 3)
    _ = try state.observe(sample(3, at: 2, actual: 56 * page), nowNanoseconds: 4)
    check(state, pending: first)
    _ = try state.observe(sample(4, at: 4, actual: 56 * page), nowNanoseconds: 4)
    check(state, pending: nil)
  }
  @Test func requestedEchoAndPartialProgressDoNotComplete() throws {
    let mib: UInt64 = 1 << 20
    let budget = try #require(
      BalloonBudget(
        installedBytes: 256 * mib, minimumResidentBytes: 128 * mib,
        granuleBytes: mib, maximumStepBytes: 32 * mib))
    guard
      var state = BalloonController(
        budget: budget, epoch: 73, guestReserveBytes: 64 * mib, hysteresisBytes: 16 * mib,
        maximumObservationAgeNanoseconds: 100, cooldownNanoseconds: 100,
        completionTimeoutNanoseconds: 1000)
    else {
      Issue.record("Valid VZ geometry refused")
      return
    }
    let first = try request(
      state.observe(
        sample(1, actual: 256 * mib, available: 128 * mib, cap: 256 * mib), nowNanoseconds: 1))
    #expect(first.targetResidentBytes == 224 * mib)
    try state.didApply(first, afterObservationSequence: 1, atNanoseconds: 1)
    _ = try state.observe(
      sample(
        2, at: 2, actual: 256 * mib, requested: 224 * mib,
        available: 128 * mib, cap: 256 * mib), nowNanoseconds: 2)
    check(state, pending: first)
    _ = try state.observe(
      sample(
        3, at: 3, actual: 256 * mib - page, requested: 224 * mib,
        available: 128 * mib, cap: 256 * mib), nowNanoseconds: 3)
    check(state, pending: first)
    _ = try state.observe(
      sample(4, at: 4, actual: 224 * mib, available: 96 * mib, cap: 256 * mib), nowNanoseconds: 4)
    check(state, pending: nil)
  }
  @Test func reserveBandAndCooldownAvoidChatter() throws {
    var state = controller()
    let held = try state.observe(sample(1, available: 12 * page), nowNanoseconds: 1)
    #expect(held == nil)
    let first = try request(state.observe(sample(2, at: 2), nowNanoseconds: 2))
    try state.didApply(first, afterObservationSequence: 2, atNanoseconds: 2)
    _ = try state.observe(sample(3, at: 3, actual: 56 * page), nowNanoseconds: 3)
    let cooled = try state.observe(sample(4, at: 4, actual: 56 * page), nowNanoseconds: 4)
    #expect(cooled == nil)
    let noisy = try state.observe(
      sample(5, at: 104, actual: 56 * page, available: 11 * page), nowNanoseconds: 104)
    #expect(noisy == nil)
    let grown = try request(
      state.observe(
        sample(6, at: 105, actual: 56 * page, available: 7 * page), nowNanoseconds: 105))
    #expect(grown.targetResidentBytes == 61 * page)
  }
  @Test func closedAdmissionStillRescuesAndCompletesOneAppliedShrink() throws {
    var state = controller()
    let first = try request(state.observe(sample(1), nowNanoseconds: 1))
    try state.didApply(first, afterObservationSequence: 1, atNanoseconds: 1)
    let rescue = try request(
      state.observe(
        sample(2, at: 2, actual: 60 * page, requested: 56 * page, available: 7 * page),
        nowNanoseconds: 2, admittingNewRequests: false))
    #expect(rescue.targetResidentBytes == 64 * page)
    #expect(rescue.supersededTargetResidentBytes == 56 * page)
    #expect(throws: BalloonController.Failure.invalidApplication) {
      try state.didApply(first, afterObservationSequence: 2, atNanoseconds: 2)
    }
    try state.didApply(rescue, afterObservationSequence: 2, atNanoseconds: 2)
    _ = try state.observe(
      sample(3, at: 3, actual: 56 * page, available: 7 * page), nowNanoseconds: 3,
      admittingNewRequests: false)
    check(state, pending: rescue)
    _ = try state.observe(sample(4, at: 4), nowNanoseconds: 4, admittingNewRequests: false)
    check(state, pending: nil)
    let stopped = try state.observe(
      sample(5, at: 104), nowNanoseconds: 104, admittingNewRequests: false)
    #expect(stopped == nil)
    let reopened = try request(state.observe(sample(6, at: 105), nowNanoseconds: 105))
    #expect(reopened.targetResidentBytes == 56 * page)
  }
  @Test(arguments: [7, 24])
  func closedAdmissionBlocksFreshGrowthAndShrinkWithoutSkippingValidation(available: UInt64) throws
  {
    var state = controller()
    let observation = sample(1, actual: 32 * page, available: available * page)
    let stopped = try state.observe(
      observation, nowNanoseconds: 1, admittingNewRequests: false)
    #expect(stopped == nil)
    check(state, pending: nil)
    #expect(throws: BalloonController.Failure.invalidObservation) {
      try state.observe(observation, nowNanoseconds: 2, admittingNewRequests: false)
    }
    let opened = try request(
      state.observe(
        sample(2, at: 2, actual: 32 * page, available: available * page), nowNanoseconds: 2))
    #expect(opened.targetResidentBytes != 32 * page)
  }
  @Test func safetyCannotStackOntoUnknownDelivery() throws {
    var state = controller()
    let first = try request(state.observe(sample(1), nowNanoseconds: 1))
    #expect(throws: BalloonController.Failure.deliveryUnknown) {
      try state.observe(sample(2, at: 2, available: page), nowNanoseconds: 2)
    }
    check(state, pending: first, reason: .deliveryUnknown)
  }
  @Test func absoluteGrantCannotBeSpentTwice() throws {
    var state = controller()
    let first = try request(
      state.observe(
        sample(1, actual: 32 * page, available: page, cap: 34 * page), nowNanoseconds: 1))
    #expect(first.targetResidentBytes == 34 * page)
    try state.didApply(first, afterObservationSequence: 1, atNanoseconds: 1)
    _ = try state.observe(
      sample(2, at: 2, actual: 34 * page, available: 3 * page, cap: 34 * page), nowNanoseconds: 2)
    let held = try state.observe(
      sample(3, at: 3, actual: 34 * page, available: page, cap: 34 * page), nowNanoseconds: 3)
    #expect(held == nil)
    check(state, pending: nil)
  }
  @Test func pressureConflictIsRecoverableButDelaysReclaim() throws {
    var state = controller()
    #expect(throws: BalloonController.Failure.pressureConflict) {
      try state.observe(sample(1, available: page, hostPressure: true), nowNanoseconds: 1)
    }
    check(state, pending: nil)
    let held = try state.observe(sample(2, at: 2), nowNanoseconds: 2)
    #expect(held == nil)
    let next = try request(state.observe(sample(3, at: 102), nowNanoseconds: 102))
    #expect(next.targetResidentBytes == 56 * page)
  }
  @Test func guestPressureVetoesShrinkAndHostPressureAllowsShrink() throws {
    var guest = controller()
    let held = try guest.observe(sample(1, guestPressure: true), nowNanoseconds: 1)
    #expect(held == nil)
    var host = controller()
    let shrink = try request(host.observe(sample(1, hostPressure: true), nowNanoseconds: 1))
    #expect(shrink.targetResidentBytes == 56 * page)
  }
  @Test func invalidAndStaleSamplesDoNotMintRequests() throws {
    let cases: [(BalloonController.Observation, BalloonController.Failure)] = [
      (sample(0), .invalidObservation), (sample(1, epoch: 74), .invalidObservation),
      (sample(1, at: 102), .invalidObservation), (sample(1, at: 0), .staleObservation),
      (sample(1, actual: 15 * page, available: page), .invalidObservation),
      (sample(1, available: 65 * page), .invalidObservation),
      (sample(1, actual: 64 * page - 1), .invalidObservation),
    ]
    for (observation, failure) in cases {
      var state = controller()
      #expect(throws: failure) { try state.observe(observation, nowNanoseconds: 101) }
      check(state, pending: nil)
      let next = try request(state.observe(sample(2, at: 101), nowNanoseconds: 101))
      #expect(next.sequence == 2)
    }
  }
  @Test func replayAndPreRequestCaptureCannotComplete() throws {
    var state = controller()
    let first = try request(state.observe(sample(1, at: 10), nowNanoseconds: 10))
    try state.didApply(first, afterObservationSequence: 1, atNanoseconds: 10)
    #expect(throws: BalloonController.Failure.invalidObservation) {
      try state.observe(sample(1, at: 11, actual: 56 * page), nowNanoseconds: 11)
    }
    #expect(throws: BalloonController.Failure.invalidObservation) {
      try state.observe(sample(2, at: 9, actual: 56 * page), nowNanoseconds: 11)
    }
    check(state, pending: first)
  }
  @Test func timeoutAndCancellationQuarantineLateReplies() throws {
    var state = controller()
    let first = try request(state.observe(sample(1), nowNanoseconds: 1))
    #expect(throws: BalloonController.Failure.completionTimedOut) {
      try state.observe(sample(2, at: 1001, actual: 56 * page), nowNanoseconds: 1001)
    }
    check(state, pending: first, reason: .completionTimedOut)
    #expect(throws: BalloonController.Failure.retired) {
      try state.observe(sample(3, at: 1002, actual: 56 * page), nowNanoseconds: 1002)
    }
    var cancelled = controller()
    let pending = try request(cancelled.observe(sample(1), nowNanoseconds: 1))
    cancelled.retire()
    #expect(throws: BalloonController.Failure.retired) {
      try cancelled.didApply(pending, afterObservationSequence: 1, atNanoseconds: 1)
    }
    check(cancelled, pending: pending, reason: .retired)
  }
  @Test func unsolicitedStateAndRevokedCapRetire() throws {
    var idle = controller()
    #expect(throws: BalloonController.Failure.inconsistentDevice) {
      try idle.observe(sample(1, requested: 56 * page), nowNanoseconds: 1)
    }
    check(idle, pending: nil, reason: .inconsistentDevice)
    var revoked = controller()
    let first = try request(revoked.observe(sample(1), nowNanoseconds: 1))
    #expect(throws: BalloonController.Failure.budgetRevoked) {
      try revoked.observe(sample(2, at: 2, cap: 56 * page), nowNanoseconds: 2)
    }
    check(revoked, pending: first, reason: .budgetRevoked)
  }
  @Test func topTimestampAndSequenceNeverWrap() throws {
    var state = controller()
    let first = try request(
      state.observe(
        sample(1, at: UInt64.max - 10), nowNanoseconds: UInt64.max - 10))
    try state.didApply(first, afterObservationSequence: 1, atNanoseconds: UInt64.max - 9)
    _ = try state.observe(sample(2, at: UInt64.max, actual: 56 * page), nowNanoseconds: UInt64.max)
    check(state, pending: nil)
    #expect(throws: BalloonController.Failure.clockRegression) {
      try state.observe(sample(3, at: 0), nowNanoseconds: 0)
    }
    check(state, pending: nil, reason: .clockRegression)
    var exhausted = controller()
    #expect(throws: BalloonController.Failure.sequenceExhausted) {
      try exhausted.observe(sample(UInt64.max), nowNanoseconds: 1)
    }
    check(exhausted, pending: nil, reason: .sequenceExhausted)
  }
  @Test func silenceExpiresWithoutAnObservation() throws {
    var state = controller()
    let first = try request(state.observe(sample(1), nowNanoseconds: 1))
    try state.didApply(first, afterObservationSequence: 1, atNanoseconds: 1)
    try state.checkDeadline(nowNanoseconds: 1000)
    check(state, pending: first)
    #expect(throws: BalloonController.Failure.completionTimedOut) {
      try state.checkDeadline(nowNanoseconds: 1001)
    }
    check(state, pending: first, reason: .completionTimedOut)
    state.retire()
    check(state, pending: first, reason: .completionTimedOut)
  }
  @Test func anExhaustedApplicationFenceCannotWaitForever() throws {
    var state = controller()
    let first = try request(state.observe(sample(1), nowNanoseconds: 1))
    #expect(throws: BalloonController.Failure.sequenceExhausted) {
      try state.didApply(first, afterObservationSequence: UInt64.max, atNanoseconds: 1)
    }
    check(state, pending: first, reason: .sequenceExhausted)
  }
  @Test func invalidConfigurationAndReserveOverflowRefuse() throws {
    let budget = try #require(
      BalloonBudget(
        installedBytes: 64 * page, minimumResidentBytes: 16 * page, granuleBytes: page,
        maximumStepBytes: 8 * page))
    let cases: [(UInt64, UInt64, UInt64, UInt64, UInt64)] = [
      (0, page, page, 100, 1000), (73, 0, page, 100, 1000),
      (73, page + 1, page, 100, 1000), (73, page, 0, 100, 1000),
      (73, 64 * page, page, 100, 1000), (73, page, UInt64.max, 100, 1000),
      (73, page, page, 0, 1000), (73, page, page, 100, 0),
    ]
    for (epoch, reserve, hysteresis, age, timeout) in cases {
      let state = BalloonController(
        budget: budget, epoch: epoch, guestReserveBytes: reserve, hysteresisBytes: hysteresis,
        maximumObservationAgeNanoseconds: age, cooldownNanoseconds: 0,
        completionTimeoutNanoseconds: timeout)
      switch consume state {
      case .none: break
      case .some: Issue.record("Invalid configuration accepted")
      }
    }
  }
}
