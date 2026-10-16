import BoundedMemory
import Foundation

/// The reason travels with the earliest deadline, including when it clamps a wire request.
struct MemoryControlFence: Sendable {
  enum Kind: Sendable, Equatable {
    case wire, capacity, completion, drain, lifetime
  }
  let instant: ContinuousClock.Instant
  let kind: Kind

  init(
    wire: ContinuousClock.Instant, capacity: ContinuousClock.Instant?,
    completion: ContinuousClock.Instant?, stoppedAt: ContinuousClock.Instant?,
    lifetime: ContinuousClock.Instant?
  ) {
    var chosen = Self(instant: wire, kind: .wire)
    func consider(_ instant: ContinuousClock.Instant?, kind: Kind) {
      if let instant, instant <= chosen.instant { chosen = Self(instant: instant, kind: kind) }
    }
    // Later entries win ties; preserve the pending controller's exact completion failure.
    consider(lifetime, kind: .lifetime)
    consider(stoppedAt?.advanced(by: .seconds(8)), kind: .drain)
    consider(capacity, kind: .capacity)
    consider(completion, kind: .completion)
    self = chosen
  }

  private init(instant: ContinuousClock.Instant, kind: Kind) {
    self.instant = instant
    self.kind = kind
  }

  func check(now: ContinuousClock.Instant) throws {
    if now >= instant { try expire() }
  }

  func expire() throws -> Never {
    switch kind {
    case .wire: throw NativeControlFailure.wireTimedOut
    case .capacity: throw NativeControlFailure.capacityTimedOut
    case .completion: throw BalloonController.Failure.completionTimedOut
    case .drain: throw NativeControlFailure.drainTimedOut
    case .lifetime: throw NativeControlFailure.lifetimeExpired
    }
  }
}

/// One unresolved Linux accounting episode; ordinary growth cannot keep re-arming it.
struct MemoryCapacityFence: Sendable {
  private(set) var deadline: ContinuousClock.Instant?
  private var restored = false

  mutating func observed(ready: Bool, hasPending: Bool, at now: ContinuousClock.Instant) {
    if ready, !hasPending {
      deadline = nil
      restored = false
    } else if !ready, deadline == nil {
      deadline = now.advanced(by: .seconds(8))
    }
  }

  mutating func issued(at now: ContinuousClock.Instant, restoringPendingShrink: Bool) {
    let next = now.advanced(by: .seconds(8))
    if let deadline {
      if restoringPendingShrink, !restored {
        self.deadline = max(deadline, next)
        restored = true
      } else {
        self.deadline = min(deadline, next)
      }
    } else {
      deadline = next
      restored = restoringPendingShrink
    }
  }
}
