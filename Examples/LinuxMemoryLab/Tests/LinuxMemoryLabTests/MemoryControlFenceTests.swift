import BoundedMemory
import Foundation
import Testing

@testable import NativeLinuxVMM

@Test func bindingMemoryFenceKeepsItsFailureAtAndAfterTheBoundary() throws {
  let began = ContinuousClock.now
  let cases: [(MemoryControlFence.Kind, Int)] = [
    (.wire, 3), (.capacity, 1), (.completion, 1), (.drain, 1), (.lifetime, 1),
  ]
  for (kind, seconds) in cases {
    let boundary = began.advanced(by: .seconds(seconds))
    let fence = MemoryControlFence(
      wire: began.advanced(by: .seconds(3)), capacity: kind == .capacity ? boundary : nil,
      completion: kind == .completion ? boundary : nil,
      stoppedAt: kind == .drain ? boundary.advanced(by: .seconds(-8)) : nil,
      lifetime: kind == .lifetime ? boundary : nil)
    #expect(fence.kind == kind && fence.instant == boundary)
    try fence.check(now: boundary.advanced(by: .nanoseconds(-1)))
    for instant in [boundary, boundary.advanced(by: .seconds(10))] {
      switch kind {
      case .wire:
        #expect(throws: NativeControlFailure.wireTimedOut) { try fence.check(now: instant) }
      case .capacity:
        #expect(throws: NativeControlFailure.capacityTimedOut) { try fence.check(now: instant) }
      case .completion:
        #expect(throws: BalloonController.Failure.completionTimedOut) {
          try fence.check(now: instant)
        }
      case .drain:
        #expect(throws: NativeControlFailure.drainTimedOut) { try fence.check(now: instant) }
      case .lifetime:
        #expect(throws: NativeControlFailure.lifetimeExpired) { try fence.check(now: instant) }
      }
    }
  }
}

@Test func rescueCannotExtendAnEarlierStopOrOwnerLifetime() throws {
  let began = ContinuousClock.now
  let stoppedAt = began.advanced(by: .seconds(1))
  let ownerEnd = began.advanced(by: .seconds(10))
  let nearDrain = began.advanced(by: .seconds(8))
  let rescued = MemoryControlFence(
    wire: nearDrain.advanced(by: .seconds(3)), capacity: began.advanced(by: .seconds(16)),
    completion: began.advanced(by: .seconds(16)), stoppedAt: stoppedAt, lifetime: ownerEnd)
  #expect(rescued.kind == .drain && rescued.instant == began.advanced(by: .seconds(9)))
  #expect(throws: NativeControlFailure.drainTimedOut) {
    try rescued.check(now: began.advanced(by: .seconds(9)))
  }
  let ownerFirst = MemoryControlFence(
    wire: nearDrain.advanced(by: .seconds(3)), capacity: nil, completion: nil, stoppedAt: stoppedAt,
    lifetime: nearDrain)
  #expect(ownerFirst.kind == .lifetime)
  #expect(throws: NativeControlFailure.lifetimeExpired) { try ownerFirst.check(now: nearDrain) }
}

@Test func equalMemoryFencesPreserveTheControllerFailure() throws {
  let boundary = ContinuousClock.now
  let fence = MemoryControlFence(
    wire: boundary, capacity: boundary, completion: boundary,
    stoppedAt: boundary.advanced(by: .seconds(-8)), lifetime: boundary)
  #expect(fence.kind == .completion && fence.instant == boundary)
  #expect(throws: BalloonController.Failure.completionTimedOut) { try fence.check(now: boundary) }
}

@Test func anUnresolvedCapacityEpisodeAllowsOnlyOneRestoreExtension() throws {
  let began = ContinuousClock.now
  var capacity = MemoryCapacityFence()
  capacity.issued(at: began, restoringPendingShrink: false)
  for second in [1, 4, 7] {
    capacity.observed(ready: false, hasPending: false, at: began.advanced(by: .seconds(second)))
    capacity.issued(at: began.advanced(by: .seconds(second)), restoringPendingShrink: false)
    #expect(capacity.deadline == began.advanced(by: .seconds(8)))
  }
  capacity.issued(at: began.advanced(by: .seconds(7)), restoringPendingShrink: true)
  #expect(capacity.deadline == began.advanced(by: .seconds(15)))
  capacity.issued(at: began.advanced(by: .seconds(13)), restoringPendingShrink: true)
  capacity.observed(ready: true, hasPending: true, at: began.advanced(by: .seconds(14)))
  #expect(capacity.deadline == began.advanced(by: .seconds(15)))
  let fence = MemoryControlFence(
    wire: began.advanced(by: .seconds(20)), capacity: capacity.deadline,
    completion: nil, stoppedAt: nil, lifetime: nil)
  #expect(throws: NativeControlFailure.capacityTimedOut) {
    try fence.check(now: began.advanced(by: .seconds(15)))
  }
  capacity.observed(ready: true, hasPending: false, at: began.advanced(by: .seconds(16)))
  #expect(capacity.deadline == nil)
  capacity.issued(at: began.advanced(by: .seconds(17)), restoringPendingShrink: false)
  #expect(capacity.deadline == began.advanced(by: .seconds(25)))
}
