import BoundedMemory
import Foundation
import PageMemory
import Synchronization

/// Experimental stock-driver controller. Run in one caller-owned task and join before VM stop.
/// The target is soft; global admission must reserve the VM's full configured peak capacity.
public final class NativeBalloonGovernor: Sendable {
  public struct State: Sendable {
    fileprivate var owner: UInt64?
    public fileprivate(set) var claimed = false
    public fileprivate(set) var running = false
    public fileprivate(set) var pending = false
    public fileprivate(set) var stopRequestedAt: ContinuousClock.Instant?
    public fileprivate(set) var stopRequestGeneration: UInt64?
    public fileprivate(set) var failureError: (any Error)?
    public fileprivate(set) var cleanupError: (any Error)?
    public fileprivate(set) var completedPulses: UInt64 = 0
    public fileprivate(set) var samples = RecentHistory<[String: UInt64]>(capacity: 256)
    public fileprivate(set) var requests = RecentHistory<[String: UInt64]>(capacity: 64)
  }
  private let state = Mutex(State())
  private let probe: NativeMemorySession
  private let vm: NativeVirtualMachine
  private let residentTarget: UInt64
  private let lifetime: ContinuousClock.Instant?
  public var snapshot: State { state.withLock { $0 } }

  public init(
    probe: NativeMemorySession, vm: NativeVirtualMachine, residentTarget: UInt64,
    lifetimeDeadline: ContinuousClock.Instant? = nil
  ) throws {
    guard residentTarget >= vm.memoryGeometry.bootBytes,
      residentTarget <= vm.memoryGeometry.maximumBytes
    else { throw NativeControlFailure.arguments }
    self.probe = probe
    self.vm = vm
    self.residentTarget = residentTarget
    lifetime = lifetimeDeadline
  }

  /// The first request closes admission and fixes the cleanup deadline. No lock crosses an await.
  public func requestStop() {
    state.withLock {
      guard $0.stopRequestedAt == nil else { return }
      $0.stopRequestedAt = .now
      if let owner = $0.owner {
        let device = vm.balloonState
        if device.settled, device.targetBytes == 0 { return }
        if let generation = Self.admittedZeroGeneration(
          device: device, lastRequest: $0.requests.elements.last) {
          $0.stopRequestGeneration = generation
          return
        }
        do {
          try vm.requestBalloon(bytes: 0, owner: owner)
          $0.stopRequestGeneration = vm.balloonState.requestGeneration
        } catch { $0.cleanupError = error }
      }
    }
  }

  static func admittedZeroGeneration(
    device: NativeBalloonState, lastRequest: [String: UInt64]?
  ) -> UInt64? {
    guard let lastRequest, lastRequest["targetBytes"] == 0,
      let generation = lastRequest["generation"], generation == device.requestGeneration else {
      return nil
    }
    return generation
  }

  private func fence(
    policy: BalloonPulsePolicy, wire: ContinuousClock.Instant
  ) -> (instant: ContinuousClock.Instant, failure: NativeControlFailure) {
    var chosen = (wire, NativeControlFailure.wireTimedOut)
    if let lifetime, lifetime <= chosen.0 { chosen = (lifetime, .lifetimeExpired) }
    if let stop = state.withLock({ $0.stopRequestedAt?.advanced(by: .seconds(8)) }),
      stop <= chosen.0
    {
      chosen = (stop, .drainTimedOut)
    }
    if let deadline = policy.deadline, deadline <= chosen.0 {
      chosen = (deadline, policy.deadlineFailure)
    }
    return chosen
  }

  private func drain(owner: UInt64, epoch: UInt64) async throws {
    guard let stoppedAt = state.withLock({ $0.stopRequestedAt }) else {
      throw NativeControlFailure.invariant
    }
    let deadline = min(
      stoppedAt.advanced(by: .seconds(8)), lifetime ?? stoppedAt.advanced(by: .seconds(8)))
    let initial = vm.balloonState
    guard initial.ready, initial.epoch == epoch else { throw NativeControlFailure.ownership }
    if initial.settled, initial.targetBytes == 0, !initial.quarantined { return }
    // A necessary zero never grants ownership, including after the wait deadline has expired.
    // Preserve an already admitted zero generation so its native application stays attributable.
    if state.withLock({ $0.stopRequestGeneration }) != initial.requestGeneration {
      try vm.requestBalloon(bytes: 0, owner: owner)
      state.withLock { $0.stopRequestGeneration = vm.balloonState.requestGeneration }
    }
    guard ContinuousClock.now < deadline else { throw NativeControlFailure.drainTimedOut }
    while true {
      guard ContinuousClock.now < deadline else { throw NativeControlFailure.drainTimedOut }
      let value = vm.balloonState
      guard value.ready, value.epoch == epoch else { throw NativeControlFailure.ownership }
      if value.settled, value.targetBytes == 0 {
        guard !value.quarantined else { throw NativeControlFailure.ownership }
        return
      }
      try await Task.sleep(until: min(.now.advanced(by: .milliseconds(20)), deadline))
    }
  }

  /// Authority and device epoch are exclusive. A failed run retires setters, but preserves deflates.
  public func run() async throws {
    try Task.checkCancellation()
    let entered = try state.withLock {
      guard !$0.claimed else { throw NativeControlFailure.ownership }
      $0.claimed = true
      guard $0.stopRequestedAt == nil else { return false }
      $0.running = true
      return true
    }
    guard entered else { return }
    let lease: (owner: UInt64, epoch: UInt64)
    do { lease = try vm.claimBalloonControl() } catch {
      state.withLock {
        $0.running = false
        $0.failureError = error
      }
      throw error
    }
    state.withLock { $0.owner = lease.owner }
    var reusable = false
    defer {
      state.withLock {
        vm.finishMemoryControl(owner: lease.owner, reusable: reusable)
        $0.owner = nil
        $0.running = false
        $0.pending = false
      }
    }
    var primary: (any Error)?
    do {
      try await withTaskCancellationHandler {
        var policy = try BalloonPulsePolicy(
          geometry: vm.memoryGeometry, epoch: lease.epoch, residentTarget: residentTarget,
          now: .now, lifetime: lifetime)
        var wire = ContinuousClock.now.advanced(by: .seconds(3))
        while true {
          try Task.checkCancellation()
          if state.withLock({ $0.stopRequestedAt != nil }) { return }
          let binding = fence(policy: policy, wire: wire)
          guard ContinuousClock.now < binding.instant else { throw binding.failure }
          let before = vm.balloonState
          let beforeCapturedAt = ContinuousClock.now
          let reply: NativeMemoryObservation?
          do {
            reply = try await probe.observeIfIdle(
              deadline: binding.instant, refreshStatistics: true)
          } catch NativeControlFailure.wireTimedOut { throw binding.failure }
          try Task.checkCancellation()
          guard ContinuousClock.now < binding.instant else { throw binding.failure }
          if let reply {
            guard reply.capturedAt >= beforeCapturedAt else { throw NativeControlFailure.invariant }
            let host = try ProcessMemorySnapshot.capture()
            guard let footprint = host.physicalFootprintBytes else {
              throw NativeControlFailure.invariant
            }
            let device = vm.balloonState
            let recycled = vm.backingRecyclingStatus.coldResidentBytes
            let finished = try state.withLock { snapshot in
              if snapshot.stopRequestedAt != nil { return true }
              let action = try policy.observe(
                reply, device: device, before: before, footprint: footprint, recycled: recycled,
                now: .now)
              switch action {
              case .inflate, .zero:
                let bytes: UInt64
                if case .inflate(let target) = action { bytes = target } else { bytes = 0 }
                // Stop/admission and setter share this lock; coordinator validates epoch again.
                try vm.requestBalloon(bytes: bytes, owner: lease.owner)
                try snapshot.requests.append([
                  "sequence": reply.sequence, "targetBytes": bytes, "epoch": lease.epoch,
                  "generation": vm.balloonState.requestGeneration,
                  "observedGeneration": before.appliedGeneration,
                  "initialOwnedBytes": before.ownedBytes,
                  "guestAvailableBytes": reply.available,
                ])
              case .finished: return true
              case .wait: break
              }
              snapshot.pending = policy.pending
              snapshot.completedPulses = policy.completedPulses
              try snapshot.samples.append([
                "sequence": reply.sequence, "guestAvailableBytes": reply.available,
                "guestTotalBytes": reply.total, "footprintBytes": footprint,
                "coldResidentBytesRecycled": recycled, "targetBytes": device.targetBytes,
                "actualBytes": device.actualBytes, "ownedBytes": device.ownedBytes,
                "completedPulses": policy.completedPulses,
                "requestGeneration": device.requestGeneration,
                "appliedGeneration": device.appliedGeneration,
                "preOwnedBytes": before.ownedBytes,
                "preTargetBytes": before.targetBytes,
                "preRequestApplied": before.requestApplied ? 1 : 0,
                "zeroTargetObserved": device.zeroTargetObserved ? 1 : 0,
              ])
              return false
            }
            if finished { return }
            let interval: Duration =
              policy.pending ? BalloonPulsePolicy.pendingInterval : .seconds(1)
            let wake = ContinuousClock.now.advanced(by: interval)
            wire = wake.advanced(by: .seconds(3))
            try await Task.sleep(until: min(wake, fence(policy: policy, wire: wire).instant))
          } else {
            try await Task.sleep(
              until: min(.now.advanced(by: .milliseconds(50)), binding.instant))
          }
        }
      } onCancel: {
        self.requestStop()
      }
    } catch {
      primary = error
      state.withLock { $0.failureError = error }
    }
    requestStop()
    do {
      // This joined child does not inherit cancellation; rescue never spins on a cancelled sleep.
      try await Task { @concurrent in
        try await self.drain(owner: lease.owner, epoch: lease.epoch)
      }.value
      if Task.isCancelled { primary = primary ?? CancellationError() }
      if primary == nil { primary = state.withLock { $0.cleanupError } }
      if let primary { state.withLock { $0.failureError = primary } }
      reusable = primary == nil
    } catch {
      state.withLock { $0.cleanupError = error }
      if primary == nil { primary = error }
    }
    if let primary { throw primary }
  }
}
