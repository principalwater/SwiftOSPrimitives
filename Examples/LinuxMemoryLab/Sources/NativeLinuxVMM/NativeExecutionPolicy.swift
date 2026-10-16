import Foundation

/// Qualification keeps the original finite guards; sustained execution needs an external owner.
public enum NativeExecutionPolicy: String, Sendable {
  case qualification
  case sustained
}

struct ExecutionFence {
  private let deadline: ContinuousClock.Instant?
  private var windowBegan: ContinuousClock.Instant
  private var windowExits = 0

  init(policy: NativeExecutionPolicy, hasDisk: Bool, now: ContinuousClock.Instant) {
    deadline = policy == .qualification ? now.advanced(by: .seconds(hasDisk ? 120 : 45)) : nil
    windowBegan = now
  }

  mutating func check(now: ContinuousClock.Instant, exits: Int) throws {
    guard now >= windowBegan, exits >= windowExits else { throw Failure.boundary }
    if let deadline {
      guard now < deadline, exits < 3_000_000 else { throw Failure.deadline }
    } else {
      // Check the completed interval before rollover; a delayed checkpoint cannot forgive a storm.
      guard exits - windowExits < 250_000 else { throw Failure.boundary }
      if windowBegan.duration(to: now) >= .seconds(1) {
        windowBegan = now
        windowExits = exits
      }
    }
  }
}
