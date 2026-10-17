/// A stopped epoch spans coordinator polling and every queued MMIO callback before resume.
struct RecyclingWindow {
  private var epoch: Int?
  private var used = 0

  mutating func admit(epoch next: Int, pending: Int) throws -> Int {
    guard next >= 0, pending >= 0, epoch.map({ next >= $0 }) ?? true else {
      throw DeviceFailure.request
    }
    if epoch != next {
      epoch = next
      used = 0
    }
    let count = min(4 - used, pending)
    used += count
    return count
  }
}
