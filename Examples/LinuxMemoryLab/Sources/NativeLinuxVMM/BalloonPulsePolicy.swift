/// A soft footprint target drives temporary ownership, never logical capacity changes.
/// Any thrown error requires the caller to retire its control authority.
struct BalloonPulsePolicy {
  static let pendingInterval = Duration.milliseconds(50)
  enum Action: Equatable {
    case wait
    case inflate(UInt64)
    case zero, finished
  }
  private enum Phase {
    case idle
    case inflating(
      bytes: UInt64, ceiling: UInt64, deadline: ContinuousClock.Instant,
      initialRecycled: UInt64)
    case draining(deadline: ContinuousClock.Instant, initialRecycled: UInt64, reachedCeiling: Bool)
    case finished
  }
  let residentTarget: UInt64
  let reserve: UInt64
  private let geometry: NativeMemoryGeometry
  private let epoch: UInt64
  private let lifetime: ContinuousClock.Instant?
  private var phase: Phase = .idle
  private var nextAdmission: ContinuousClock.Instant
  private var previousAvailable: UInt64?
  private var previousSequence: UInt64 = 0
  private var expectedGuestTotal: UInt64?
  private var previousRecycled: UInt64 = 0
  private var lastRequestAt: ContinuousClock.Instant?
  private var lastDrainedFootprint: UInt64?
  private var unreachableFloor: (footprint: UInt64, available: UInt64)?
  private var backoff: Duration = .seconds(1)
  private var admissionFootprint: UInt64 = 0
  private(set) var completedPulses: UInt64 = 0
  private(set) var lastProgressBytes: UInt64 = 0

  init(
    geometry: NativeMemoryGeometry, epoch: UInt64, residentTarget: UInt64,
    reserve: UInt64 = 512 << 20, now: ContinuousClock.Instant,
    lifetime: ContinuousClock.Instant? = nil
  ) throws {
    guard epoch > 0, residentTarget >= geometry.bootBytes,
      residentTarget <= geometry.maximumBytes, reserve >= 512 << 20,
      reserve < geometry.maximumBytes
    else { throw NativeControlFailure.arguments }
    self.geometry = geometry
    self.epoch = epoch
    self.residentTarget = residentTarget
    self.reserve = reserve
    self.lifetime = lifetime
    nextAdmission = now.advanced(by: .milliseconds(300))
  }

  var pending: Bool {
    switch phase {
    case .inflating, .draining: true
    default: false
    }
  }
  var deadline: ContinuousClock.Instant? {
    switch phase {
    case .inflating(_, _, let deadline, _), .draining(let deadline, _, _): deadline
    default: nil
    }
  }

  var deadlineFailure: NativeControlFailure {
    if case .draining = phase { return .drainTimedOut }
    return .pulseTimedOut
  }

  mutating func observe(
    _ sample: NativeMemoryObservation, device: NativeBalloonState, before: NativeBalloonState,
    footprint: UInt64, recycled: UInt64, now: ContinuousClock.Instant,
    stoppedAt: ContinuousClock.Instant? = nil
  ) throws -> Action {
    guard sample.sequence > previousSequence, sample.total >= geometry.dynamicBytes,
      sample.total <= geometry.maximumBytes, sample.available <= sample.total,
      expectedGuestTotal.map({ sample.total == $0 }) ?? true,
      sample.capturedAt <= now, stoppedAt.map({ $0 <= now }) ?? true,
      lastRequestAt.map({ sample.capturedAt >= $0 }) ?? true,
      recycled >= previousRecycled
    else { throw NativeControlFailure.invariant }
    guard sample.capturedAt.duration(to: now) <= .seconds(3) else {
      throw NativeControlFailure.staleObservation
    }
    guard device.epoch == epoch, before.epoch == epoch,
      !device.quarantined, !before.quarantined
    else {
      throw NativeControlFailure.ownership
    }
    guard before.ready, before.requestGeneration == device.requestGeneration,
      before.appliedGeneration <= before.requestGeneration,
      device.appliedGeneration <= device.requestGeneration,
      before.ownedBytes <= geometry.dynamicBytes,
      device.ready, device.targetBytes <= geometry.dynamicBytes,
      device.actualBytes <= geometry.dynamicBytes, device.ownedBytes <= geometry.dynamicBytes
    else { throw NativeControlFailure.unsettled }
    let wasAvailable = previousAvailable
    previousAvailable = sample.available
    previousSequence = sample.sequence
    previousRecycled = recycled
    expectedGuestTotal = sample.total
    if let stoppedAt, now >= stoppedAt.advanced(by: .seconds(8)) {
      throw NativeControlFailure.drainTimedOut
    }
    if let lifetime, now >= lifetime {
      throw NativeControlFailure.lifetimeExpired
    }
    switch phase {
    case .idle:
      guard device.settled, device.targetBytes == 0 else { throw NativeControlFailure.unsettled }
      guard before.settled, before.targetBytes == 0 else { return .wait }
      if stoppedAt != nil {
        phase = .finished
        return .finished
      }
      if let floor = unreachableFloor {
        let grew = footprint > floor.footprint && footprint - floor.footprint >= 128 << 20
        let freed =
          sample.available > floor.available
          && sample.available - floor.available >= 128 << 20
        guard grew || freed else { return .wait }
        unreachableFloor = nil
        backoff = .seconds(1)
        nextAdmission = min(nextAdmission, now.advanced(by: .milliseconds(300)))
      }
      if let wasAvailable, wasAvailable > sample.available,
        wasAvailable - sample.available > 32 << 20
      {
        nextAdmission = max(nextAdmission, now.advanced(by: .milliseconds(300)))
      }
      if let lastDrainedFootprint, footprint > lastDrainedFootprint,
        footprint - lastDrainedFootprint >= 128 << 20
      {
        backoff = .seconds(1)
        nextAdmission = min(nextAdmission, now.advanced(by: .milliseconds(300)))
      }
      guard now >= nextAdmission, footprint > residentTarget,
        sample.available >= reserve,
        lifetime.map({ now.advanced(by: .seconds(16)) <= $0 }) ?? true
      else { return .wait }
      let maximum = min(geometry.dynamicBytes, 2 << 30)
      let ceiling = min(sample.available - reserve, maximum) / (2 << 20) * (2 << 20)
      guard ceiling >= min(128 << 20, maximum) else { return .wait }
      let bytes = min(128 << 20, ceiling)
      admissionFootprint = footprint
      phase = .inflating(
        bytes: bytes, ceiling: ceiling,
        deadline: now.advanced(by: .seconds(8)), initialRecycled: recycled)
      lastRequestAt = now
      return .inflate(bytes)
    case .inflating(let bytes, let ceiling, let deadline, let initialRecycled):
      guard now < deadline else { throw NativeControlFailure.pulseTimedOut }
      guard !device.requestApplied || device.targetBytes == bytes else {
        throw NativeControlFailure.unsettled
      }
      // Available is an admission interlock, never attribution or peak-capacity credit.
      let headroom = sample.available > reserve ? sample.available - reserve : 0
      let settled = device.settled && before.settled && before.targetBytes == bytes
      // New guest headroom is usable only after ownership was settled before the wire sample.
      let bound = settled ? min(geometry.dynamicBytes, 2 << 30) : ceiling
      let safeCeiling = min(bound, before.ownedBytes + headroom) / (2 << 20) * (2 << 20)
      let reached = settled && bytes >= safeCeiling
      if stoppedAt != nil || sample.available < reserve || footprint <= residentTarget
        || safeCeiling < bytes || reached
        // Reserve the bounded three-second wire round trip and one second for native delivery.
        || now >= deadline.advanced(by: Duration.seconds(-4) - Self.pendingInterval)
      {
        var until = now.advanced(by: .seconds(8))
        if let stoppedAt { until = min(until, stoppedAt.advanced(by: .seconds(8))) }
        if let lifetime { until = min(until, lifetime) }
        phase = .draining(
          deadline: until, initialRecycled: initialRecycled,
          reachedCeiling: (reached || safeCeiling < bytes)
            && footprint > residentTarget && sample.available >= reserve)
        lastRequestAt = now
        return .zero
      }
      if settled {
        let next = min(safeCeiling, bytes + (128 << 20))
        phase = .inflating(
          bytes: next, ceiling: safeCeiling, deadline: deadline,
          initialRecycled: initialRecycled)
        lastRequestAt = now
        return .inflate(next)
      }
      phase = .inflating(
        bytes: bytes, ceiling: ceiling, deadline: deadline,
        initialRecycled: initialRecycled)
      return .wait
    case .draining(let deadline, let initialRecycled, let reachedCeiling):
      guard now < deadline else { throw NativeControlFailure.drainTimedOut }
      guard device.settled, device.targetBytes == 0,
        before.settled, before.targetBytes == 0
      else { return .wait }
      guard completedPulses < .max else { throw NativeControlFailure.invariant }
      completedPulses += 1
      lastProgressBytes = recycled - initialRecycled
      let retainedBenefit = admissionFootprint > footprint ? admissionFootprint - footprint : 0
      if lastProgressBytes < 16 << 20 || retainedBenefit < 16 << 20 {
        backoff = min(backoff * 2, .seconds(60))
      }
      if reachedCeiling { unreachableFloor = (footprint, sample.available) }
      lastDrainedFootprint = footprint
      nextAdmission = now.advanced(by: backoff)
      phase = stoppedAt == nil ? .idle : .finished
      return stoppedAt == nil ? .wait : .finished
    case .finished: throw NativeControlFailure.ownership
    }
  }
}
