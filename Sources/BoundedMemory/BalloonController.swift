/// Serial planning for one guest epoch; never a physical-memory authority.
/// The owner authenticates samples, reserves a per-VM cap and owns native transport/cleanup.
public struct BalloonController: ~Copyable {
  public enum Failure: Error, Equatable, Sendable {
    case retired, invalidObservation, staleObservation, clockRegression
    case completionTimedOut, inconsistentDevice, pressureConflict, budgetRevoked
    case invalidApplication, deliveryUnknown, sequenceExhausted
  }
  /// Logical allowance, not RSS/MemTotal. Capture time is the earliest component's host instant.
  public struct Observation: Sendable {
    public let epoch: UInt64
    public let sequence: UInt64
    public let capturedAtNanoseconds: UInt64
    public let actualResidentBytes: UInt64
    public let requestedResidentBytes: UInt64
    public let guestAvailableBytes: UInt64
    /// Absolute reserved allowance cap; never raw, reusable host free-memory headroom.
    public let hostResidentLimitBytes: UInt64
    public let hostUnderPressure: Bool
    public let guestUnderPressure: Bool
    public init(
      epoch: UInt64, sequence: UInt64, capturedAtNanoseconds: UInt64,
      actualResidentBytes: UInt64, requestedResidentBytes: UInt64,
      guestAvailableBytes: UInt64, hostResidentLimitBytes: UInt64,
      hostUnderPressure: Bool, guestUnderPressure: Bool
    ) {
      self.epoch = epoch
      self.sequence = sequence
      self.capturedAtNanoseconds = capturedAtNanoseconds
      self.actualResidentBytes = actualResidentBytes
      self.requestedResidentBytes = requestedResidentBytes
      self.guestAvailableBytes = guestAvailableBytes
      self.hostResidentLimitBytes = hostResidentLimitBytes
      self.hostUnderPressure = hostUnderPressure
      self.guestUnderPressure = guestUnderPressure
    }
  }
  /// A plan. Call didApply only after the matching setter returns on its owning queue.
  public struct Request: Equatable, Sendable {
    public let epoch: UInt64
    public let sequence: UInt64
    public let issuedAtNanoseconds: UInt64
    public let initialResidentBytes: UInt64
    public let targetResidentBytes: UInt64
    /// A rescue may replace one applied shrink; its late device state remains recognizable.
    public let supersededTargetResidentBytes: UInt64?
  }
  public let budget: BalloonBudget
  public let epoch: UInt64
  public private(set) var pendingRequest: Request?
  public private(set) var retirementReason: Failure?
  public var isRetired: Bool { retirementReason != nil }
  private let guestReserveBytes: UInt64
  private let hysteresisBytes: UInt64
  private let maximumObservationAgeNanoseconds: UInt64
  private let cooldownNanoseconds: UInt64
  private let completionTimeoutNanoseconds: UInt64
  private var latestSequence: UInt64 = 0
  private var latestCapture: UInt64 = 0
  private var latestNow: UInt64 = 0
  private var lastSafetyEventAt: UInt64?
  private var appliedAt: UInt64?
  private var appliedAfterSequence: UInt64 = 0

  /// Assign a new epoch only after retiring/joining the old backend. Durations and capture
  /// times share one host-monotonic clock including sleep; drain or retire before VM pause.
  public init?(
    budget: BalloonBudget, epoch: UInt64, guestReserveBytes: UInt64,
    hysteresisBytes: UInt64, maximumObservationAgeNanoseconds: UInt64,
    cooldownNanoseconds: UInt64, completionTimeoutNanoseconds: UInt64
  ) {
    guard epoch != 0, guestReserveBytes > 0, guestReserveBytes <= budget.installedBytes,
      guestReserveBytes % budget.granuleBytes == 0,
      hysteresisBytes >= budget.granuleBytes,
      hysteresisBytes <= budget.installedBytes - guestReserveBytes,
      hysteresisBytes % budget.granuleBytes == 0,
      maximumObservationAgeNanoseconds > 0, completionTimeoutNanoseconds > 0
    else { return nil }
    self.budget = budget
    self.epoch = epoch
    self.guestReserveBytes = guestReserveBytes
    self.hysteresisBytes = hysteresisBytes
    self.maximumObservationAgeNanoseconds = maximumObservationAgeNanoseconds
    self.cooldownNanoseconds = cooldownNanoseconds
    self.completionTimeoutNanoseconds = completionTimeoutNanoseconds
  }
  /// Sticky quarantine, preserving uncertain delivery for diagnosis; does not cancel native IO.
  public mutating func retire() {
    if retirementReason == nil { retirementReason = .retired }
  }
  private mutating func fail(_ reason: Failure) throws(Failure) -> Never {
    retirementReason = reason
    throw reason
  }
  private mutating func advance(to now: UInt64) throws(Failure) {
    guard !isRetired else { throw .retired }
    guard now >= latestNow else { try fail(.clockRegression) }
    latestNow = now
    if let pendingRequest,
      now - pendingRequest.issuedAtNanoseconds >= completionTimeoutNanoseconds
    {
      try fail(.completionTimedOut)
    }
  }
  /// The adapter calls this at its response deadline even when the guest is completely silent.
  public mutating func checkDeadline(nowNanoseconds now: UInt64) throws(Failure) {
    try advance(to: now)
  }
  /// Fence all sample requests sent before setter return, including queued/unparsed replies.
  /// This acknowledges delivery only; it never completes a balloon operation.
  public mutating func didApply(
    _ request: Request, afterObservationSequence sequence: UInt64, atNanoseconds now: UInt64
  ) throws(Failure) {
    try advance(to: now)
    guard pendingRequest == request, appliedAt == nil,
      sequence >= latestSequence, sequence >= request.sequence
    else { throw .invalidApplication }
    guard sequence < UInt64.max else { try fail(.sequenceExhausted) }
    appliedAt = now
    appliedAfterSequence = sequence
  }
  private mutating func issue(
    sequence: UInt64, now: UInt64, initial: UInt64, target: UInt64, superseded: UInt64? = nil
  ) throws(Failure) -> Request {
    guard sequence < UInt64.max else { try fail(.sequenceExhausted) }
    let request = Request(
      epoch: epoch, sequence: sequence, issuedAtNanoseconds: now,
      initialResidentBytes: initial, targetResidentBytes: target,
      supersededTargetResidentBytes: superseded)
    pendingRequest = request
    appliedAt = nil
    return request
  }
  /// One bounded request or nil for stable/pending/cooldown. A low-reserve guest may replace
  /// one applied shrink with restoration of its previously reserved allowance. Unknown delivery
  /// or conflicting host pressure quarantines it instead of stacking uncertain writes.
  /// Closing admission still validates observations, completes pending work and permits its rescue.
  public mutating func observe(
    _ sample: borrowing Observation, nowNanoseconds now: UInt64,
    admittingNewRequests: Bool = true
  )
    throws(Failure) -> Request?
  {
    try advance(to: now)
    guard sample.epoch == epoch, sample.sequence > latestSequence,
      sample.capturedAtNanoseconds >= latestCapture, sample.capturedAtNanoseconds <= now,
      sample.guestAvailableBytes <= sample.actualResidentBytes,
      sample.hostResidentLimitBytes <= budget.installedBytes,
      sample.actualResidentBytes >= budget.minimumResidentBytes,
      sample.actualResidentBytes <= budget.installedBytes,
      // Device progress may use4KiB pages while request granules are coarser.
      sample.actualResidentBytes % 4096 == 0,
      budget.target(
        observedResidentBytes: sample.requestedResidentBytes,
        requestedResidentBytes: sample.requestedResidentBytes) == sample.requestedResidentBytes
    else { throw .invalidObservation }
    guard now - sample.capturedAtNanoseconds <= maximumObservationAgeNanoseconds else {
      throw .staleObservation
    }
    guard sample.hostResidentLimitBytes >= sample.actualResidentBytes,
      sample.hostResidentLimitBytes >= sample.requestedResidentBytes
    else { try fail(.budgetRevoked) }
    let belowReserve = sample.guestAvailableBytes < guestReserveBytes
    let needsSafety = sample.guestUnderPressure || belowReserve
    if needsSafety { lastSafetyEventAt = now }
    if let pendingRequest {
      guard sample.capturedAtNanoseconds >= pendingRequest.issuedAtNanoseconds else {
        throw .invalidObservation
      }
      let oldTarget =
        pendingRequest.supersededTargetResidentBytes ?? pendingRequest.targetResidentBytes
      let lower = min(
        oldTarget, min(pendingRequest.initialResidentBytes, pendingRequest.targetResidentBytes))
      let upper = max(
        oldTarget, max(pendingRequest.initialResidentBytes, pendingRequest.targetResidentBytes))
      let requested = sample.requestedResidentBytes
      guard (lower...upper).contains(sample.actualResidentBytes),
        requested == pendingRequest.initialResidentBytes
          || requested == pendingRequest.targetResidentBytes
          || requested == oldTarget
      else { try fail(.inconsistentDevice) }
      guard sample.hostResidentLimitBytes >= upper else { try fail(.budgetRevoked) }
      latestSequence = sample.sequence
      latestCapture = sample.capturedAtNanoseconds
      if needsSafety, pendingRequest.targetResidentBytes < pendingRequest.initialResidentBytes {
        guard appliedAt != nil else { try fail(.deliveryUnknown) }
        guard !sample.hostUnderPressure else { try fail(.pressureConflict) }
        return try issue(
          sequence: sample.sequence, now: now, initial: pendingRequest.initialResidentBytes,
          target: pendingRequest.initialResidentBytes,
          superseded: pendingRequest.targetResidentBytes)
      }
      if let appliedAt, sample.capturedAtNanoseconds >= appliedAt,
        sample.sequence > appliedAfterSequence,
        sample.actualResidentBytes == pendingRequest.targetResidentBytes,
        requested == pendingRequest.targetResidentBytes
      {
        self.pendingRequest = nil
        self.appliedAt = nil
        lastSafetyEventAt = now
      }
      return nil
    }
    guard sample.actualResidentBytes == sample.requestedResidentBytes else {
      try fail(.inconsistentDevice)
    }
    latestSequence = sample.sequence
    latestCapture = sample.capturedAtNanoseconds
    guard admittingNewRequests else { return nil }
    let highWater = guestReserveBytes + hysteresisBytes
    let desired: UInt64
    if needsSafety {
      guard sample.guestAvailableBytes < highWater else { return nil }
      guard !sample.hostUnderPressure else { throw .pressureConflict }
      let deficit = highWater - sample.guestAvailableBytes
      let headroom = sample.hostResidentLimitBytes - sample.actualResidentBytes
      let increase = min(deficit, headroom) / budget.granuleBytes * budget.granuleBytes
      desired = sample.actualResidentBytes + increase
    } else {
      if let lastSafetyEventAt, now - lastSafetyEventAt < cooldownNanoseconds { return nil }
      guard sample.guestAvailableBytes > highWater else { return nil }
      desired = sample.actualResidentBytes - (sample.guestAvailableBytes - highWater)
    }
    guard
      let target = budget.target(
        observedResidentBytes: sample.actualResidentBytes, requestedResidentBytes: desired),
      target != sample.actualResidentBytes
    else { return nil }
    return try issue(
      sequence: sample.sequence, now: now, initial: sample.actualResidentBytes, target: target)
  }
}
