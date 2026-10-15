#if !BOUNDEDMEMORY_STANDALONE
  import BoundedMemory
#endif

@main struct EmbeddedBalloonProbe {
  static func run() throws(BalloonController.Failure) {
    let page: UInt64 = 4096
    guard
      let budget = BalloonBudget(
        installedBytes: 64 * page, minimumResidentBytes: 16 * page, granuleBytes: page,
        maximumStepBytes: 8 * page),
      var state = BalloonController(
        budget: budget, epoch: 73, guestReserveBytes: 8 * page, hysteresisBytes: 4 * page,
        maximumObservationAgeNanoseconds: 10, cooldownNanoseconds: 10,
        completionTimeoutNanoseconds: 100)
    else { preconditionFailure("Invalid geometry") }
    func observation(_ sequence: UInt64, actual: UInt64, available: UInt64)
      -> BalloonController.Observation
    {
      .init(
        epoch: 73, sequence: sequence, capturedAtNanoseconds: sequence,
        actualResidentBytes: actual, requestedResidentBytes: actual,
        guestAvailableBytes: available, hostResidentLimitBytes: 64 * page,
        hostUnderPressure: false, guestUnderPressure: false)
    }
    var sequence: UInt64 = 1
    var digest: UInt64 = 0
    for _ in 0..<1000 {
      let shrink = try state.observe(
        observation(sequence, actual: 64 * page, available: 24 * page),
        nowNanoseconds: sequence)
      guard let shrink, shrink.targetResidentBytes == 56 * page else {
        preconditionFailure("Bounded shrink missing")
      }
      digest += shrink.targetResidentBytes / page
      try state.didApply(shrink, afterObservationSequence: sequence, atNanoseconds: sequence)
      sequence += 1
      _ = try state.observe(
        observation(sequence, actual: 56 * page, available: 16 * page),
        nowNanoseconds: sequence)
      precondition(state.pendingRequest == nil)
      sequence += 1
      let grow = try state.observe(
        observation(sequence, actual: 56 * page, available: page), nowNanoseconds: sequence)
      guard let grow, grow.targetResidentBytes == 64 * page else {
        preconditionFailure("Urgent growth missing")
      }
      digest += grow.targetResidentBytes / page
      try state.didApply(grow, afterObservationSequence: sequence, atNanoseconds: sequence)
      sequence += 1
      _ = try state.observe(
        observation(sequence, actual: 64 * page, available: 16 * page),
        nowNanoseconds: sequence)
      sequence += 20
    }
    precondition(digest == 120000 && state.pendingRequest == nil)
    _ = try state.observe(
      observation(sequence, actual: 64 * page, available: 24 * page), nowNanoseconds: sequence)
    do {
      try state.checkDeadline(nowNanoseconds: sequence + 100)
      preconditionFailure("Timeout accepted")
    } catch {
      precondition(error == .completionTimedOut && state.isRetired)
    }
    do {
      _ = try state.observe(
        observation(sequence + 101, actual: 56 * page, available: 16 * page),
        nowNanoseconds: sequence + 101)
      preconditionFailure("Retired epoch revived")
    } catch { precondition(error == .retired) }
  }
  static func main() {
    do { try run() } catch { preconditionFailure("Balloon control refused") }
  }
}
