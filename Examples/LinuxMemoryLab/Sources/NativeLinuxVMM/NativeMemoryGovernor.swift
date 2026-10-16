import BoundedMemory
import Darwin
import Foundation
import Synchronization

/// One caller-owned task. No stored Task can keep the governor alive after its owner exits.
public final class NativeMemoryGovernor: Sendable {
  public struct State: Sendable {
    public fileprivate(set) var claimed = false
    public fileprivate(set) var running = false
    public fileprivate(set) var stopRequestedAt: ContinuousClock.Instant?
    public fileprivate(set) var pending = false
    public fileprivate(set) var capacityReady = false
    public fileprivate(set) var failureError: (any Error)?
    public var failure: String { failureError.map { String(describing: $0) } ?? "" }
    public var stop: Bool { stopRequestedAt != nil }
    public fileprivate(set) var activeRequest: [String: UInt64] = [:]
    public fileprivate(set) var sampleHistory = RecentHistory<[String: UInt64]>(capacity: 512)
    public fileprivate(set) var requestHistory = RecentHistory<[String: UInt64]>(capacity: 32)
    public var samples: [[String: UInt64]] { sampleHistory.elements }
    public var requests: [[String: UInt64]] { requestHistory.elements }
  }
  private let state = Mutex(State())
  private let probe: NativeMemorySession
  private let vm: NativeVirtualMachine
  private let bootGuestBytes: UInt64
  private let began: ContinuousClock.Instant
  private let lifetimeDeadline: ContinuousClock.Instant?
  private let samplingInterval: Duration
  public var snapshot: State { state.withLock { $0 } }
  public var status:
    (
      running: Bool, pending: Bool, failure: String, sampleCount: Int, capacityReady: Bool
    )
  {
    state.withLock {
      (
        $0.running, $0.pending, $0.failure, Int(clamping: $0.sampleHistory.totalCount),
        $0.capacityReady
      )
    }
  }
  public init(
    probe: NativeMemorySession, vm: NativeVirtualMachine, began: ContinuousClock.Instant,
    bootGuestBytes: UInt64, lifetimeDeadline: ContinuousClock.Instant? = nil,
    samplingInterval: Duration = .milliseconds(200)
  ) {
    self.probe = probe
    self.vm = vm
    self.began = began
    self.bootGuestBytes = bootGuestBytes
    precondition(began <= .now && bootGuestBytes <= UInt64.max - vm.memoryGeometry.dynamicBytes)
    precondition(samplingInterval >= .milliseconds(100) && samplingInterval <= .seconds(1))
    self.lifetimeDeadline = lifetimeDeadline
    self.samplingInterval = samplingInterval
  }
  /// Closes new admissions immediately; the first request fixes an eight-second drain limit.
  public func requestStop() {
    state.withLock { if $0.stopRequestedAt == nil { $0.stopRequestedAt = .now } }
  }
  private func elapsed(at instant: ContinuousClock.Instant) throws -> UInt64 {
    guard instant >= began else { throw NativeControlFailure.invariant }
    let d = began.duration(to: instant).components
    let seconds = UInt64(d.seconds).multipliedReportingOverflow(by: 1_000_000_000)
    let value = seconds.partialValue.addingReportingOverflow(UInt64(d.attoseconds / 1_000_000_000))
    guard !seconds.overflow, !value.overflow,
      value.partialValue <= UInt64(Int64.max) - 8_000_000_000
    else { throw NativeControlFailure.invariant }
    return value.partialValue
  }
  private func fence(
    wire: ContinuousClock.Instant, capacity: ContinuousClock.Instant?,
    pending: BalloonController.Request?, stoppedAt: ContinuousClock.Instant?
  ) -> MemoryControlFence {
    MemoryControlFence(
      wire: wire, capacity: capacity,
      completion: pending.map {
        began.advanced(by: .nanoseconds(Int64($0.issuedAtNanoseconds) + 8_000_000_000))
      }, stoppedAt: stoppedAt, lifetime: lifetimeDeadline)
  }
  /// Run once in an owner task and join it before stopping the VM. A failed run quarantines
  /// further memory setters until the VM is retired; it does not destroy the owner's VM.
  public func run() async throws {
    try Task.checkCancellation()
    try state.withLock {
      guard !$0.claimed else { throw NativeControlFailure.invariant }
      $0.claimed = true
      $0.running = true
    }
    let geometry = vm.memoryGeometry
    guard
      let budget = BalloonBudget(
        installedBytes: geometry.maximumBytes, minimumResidentBytes: geometry.bootBytes,
        granuleBytes: 2 << 20, maximumStepBytes: min(128 << 20, geometry.dynamicBytes)),
      var controller = BalloonController(
        budget: budget, epoch: 1, guestReserveBytes: 512 << 20, hysteresisBytes: 32 << 20,
        maximumObservationAgeNanoseconds: 3_000_000_000, cooldownNanoseconds: 500_000_000,
        completionTimeoutNanoseconds: 8_000_000_000)
    else {
      state.withLock {
        $0.running = false
        $0.failureError = NativeControlFailure.invariant
      }
      throw NativeControlFailure.invariant
    }
    let lease: UInt64
    do { lease = try vm.claimMemoryControl() } catch {
      state.withLock {
        $0.running = false
        $0.failureError = error
      }
      throw error
    }
    var reusable = false
    var capacityFence = MemoryCapacityFence()
    var observationDeadline = ContinuousClock.now.advanced(by: .seconds(3))
    defer {
      controller.retire()
      vm.finishMemoryControl(owner: lease, reusable: reusable)
      state.withLock { $0.running = false }
    }
    do {
      while true {
        try Task.checkCancellation()
        let stoppedAt = state.withLock { $0.stopRequestedAt }
        if let stoppedAt, lifetimeDeadline.map({ stoppedAt < $0 }) ?? true,
          controller.pendingRequest == nil, capacityFence.deadline == nil
        {
          reusable = true
          return
        }
        guard state.withLock({ $0.sampleHistory.remainingCounterValues > 0 }) else {
          throw NativeControlFailure.invariant
        }
        let activeFence = fence(
          wire: observationDeadline, capacity: capacityFence.deadline,
          pending: controller.pendingRequest, stoppedAt: stoppedAt)
        try activeFence.check(now: .now)
        try controller.checkDeadline(nowNanoseconds: elapsed(at: .now))
        let deadline = activeFence.instant
        // Do not put an ambiguous command on the shared wire just as a fence expires.
        if deadline < ContinuousClock.now.advanced(by: .milliseconds(50)) {
          try await Task.sleep(until: deadline, clock: .continuous)
          continue
        }
        let observation: NativeMemoryObservation?
        do {
          observation = try await probe.observeIfIdle(deadline: deadline)
        } catch NativeControlFailure.wireTimedOut {
          try activeFence.expire()
        }
        guard let reply = observation else {
          try await Task.sleep(
            until: min(.now.advanced(by: samplingInterval), deadline), clock: .continuous)
          continue
        }
        try Task.checkCancellation()
        try activeFence.check(now: .now)
        var pressure: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0) == 0,
          size == MemoryLayout<Int32>.size, [1, 2, 4].contains(pressure)
        else { throw NativeControlFailure.invariant }
        let device = vm.memoryState
        try Task.checkCancellation()
        let returnedInstant = ContinuousClock.now
        let returnedAt = try elapsed(at: returnedInstant)
        try fence(
          wire: observationDeadline, capacity: capacityFence.deadline,
          pending: controller.pendingRequest, stoppedAt: state.withLock { $0.stopRequestedAt }
        ).check(now: returnedInstant)
        try controller.checkDeadline(nowNanoseconds: returnedAt)
        guard reply.capturedAt <= returnedInstant else {
          throw NativeControlFailure.invariant
        }
        guard reply.capturedAt.duration(to: returnedInstant) <= .seconds(3) else {
          throw NativeControlFailure.staleObservation
        }
        let capturedAt = try elapsed(at: reply.capturedAt)
        guard reply.total >= bootGuestBytes, reply.total <= bootGuestBytes + geometry.dynamicBytes,
          device.pluggedBytes <= geometry.dynamicBytes,
          device.requestedBytes <= geometry.dynamicBytes
        else { throw NativeControlFailure.invariant }
        let capacityReady = reply.total == bootGuestBytes + device.pluggedBytes
        capacityFence.observed(
          ready: capacityReady, hasPending: controller.pendingRequest != nil, at: returnedInstant)
        let sample = BalloonController.Observation(
          epoch: 1, sequence: reply.sequence, capturedAtNanoseconds: capturedAt,
          actualResidentBytes: geometry.bootBytes + device.pluggedBytes,
          requestedResidentBytes: geometry.bootBytes + device.requestedBytes,
          guestAvailableBytes: reply.available, hostResidentLimitBytes: geometry.maximumBytes,
          hostUnderPressure: pressure != 1, guestUnderPressure: false)
        // No suspension between policy admission, native setter and delivery fence.
        // Native mapping completion can precede Linux memory-online accounting.
        // Stop and new admissions share one linearization point; no lock crosses an await.
        try state.withLock { snapshot in
          try fence(
            wire: observationDeadline, capacity: capacityFence.deadline,
            pending: controller.pendingRequest, stoppedAt: snapshot.stopRequestedAt
          ).check(now: .now)
          let request: BalloonController.Request?
          let lifetimeAdmits =
            lifetimeDeadline.map {
              ContinuousClock.now.advanced(by: .seconds(8)) <= $0
            } ?? true
          if capacityReady || controller.pendingRequest != nil || reply.available < 512 << 20 {
            request = try controller.observe(
              sample, nowNanoseconds: returnedAt,
              admittingNewRequests: !snapshot.stop && lifetimeAdmits)
          } else {
            request = nil
          }
          if let request {
            guard snapshot.requestHistory.remainingCounterValues > 0 else {
              throw NativeControlFailure.invariant
            }
            snapshot.pending = true
            snapshot.activeRequest = [
              "initialBytes": request.initialResidentBytes,
              "targetBytes": request.targetResidentBytes, "sequence": request.sequence,
              "issuedAt": request.issuedAtNanoseconds,
              "rescue": request.supersededTargetResidentBytes == nil ? 0 : 1,
            ]
            capacityFence.issued(
              at: began.advanced(by: .nanoseconds(Int64(request.issuedAtNanoseconds))),
              restoringPendingShrink: request.supersededTargetResidentBytes != nil)
            try vm.requestMemory(
              bytes: request.targetResidentBytes - geometry.bootBytes, owner: lease)
            let deliveredAt = try elapsed(at: .now)
            snapshot.activeRequest["deliveredAt"] = deliveredAt
            if let superseded = request.supersededTargetResidentBytes {
              snapshot.activeRequest["supersededTargetBytes"] = superseded
            }
            if let stoppedAt = snapshot.stopRequestedAt {
              snapshot.activeRequest["stopRequestedAt"] = try elapsed(at: stoppedAt)
            }
            try snapshot.requestHistory.append(snapshot.activeRequest)
            try controller.didApply(
              request, afterObservationSequence: reply.sequence, atNanoseconds: deliveredAt)
          }
          capacityFence.observed(
            ready: capacityReady, hasPending: controller.pendingRequest != nil, at: returnedInstant)
          let pending = controller.pendingRequest != nil || capacityFence.deadline != nil
          snapshot.pending = pending
          if !pending { snapshot.activeRequest = [:] }
          snapshot.capacityReady = capacityReady
          try snapshot.sampleHistory.append([
            "sequence": reply.sequence, "capturedAt": capturedAt, "returnedAt": returnedAt,
            "guestAvailableBytes": reply.available, "guestTotalBytes": reply.total,
            "pluggedBytes": device.pluggedBytes, "requestedBytes": device.requestedBytes,
            "hostPressure": UInt64(pressure), "pending": pending ? 1 : 0,
            "guestCapacityReady": capacityReady ? 1 : 0,
          ])
        }
        let nextSample = ContinuousClock.now.advanced(by: samplingInterval)
        observationDeadline = nextSample.advanced(by: .seconds(3))
        let wake = min(
          nextSample,
          fence(
            wire: observationDeadline, capacity: capacityFence.deadline,
            pending: controller.pendingRequest, stoppedAt: state.withLock { $0.stopRequestedAt }
          ).instant)
        try await Task.sleep(until: wake, clock: .continuous)
      }
    } catch {
      state.withLock {
        $0.failureError = error
      }
      throw error
    }
  }
}
