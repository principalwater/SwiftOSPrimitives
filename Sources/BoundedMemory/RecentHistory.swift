/// Fixed-capacity recent telemetry. Dropping old records never ends the owning operation.
public struct RecentHistory<Element> {
  public enum Failure: Error { case counterOverflow }
  public let capacity: Int
  public private(set) var totalCount: UInt64 = 0
  private var storage: [Element] = []
  private var next = 0

  /// Capacity is a trusted allocation bound, between 1 and 16,384 records.
  public init(capacity: Int) {
    precondition((1...16384).contains(capacity))
    self.capacity = capacity
    storage.reserveCapacity(capacity)
  }
  public var count: Int { storage.count }
  public var droppedCount: UInt64 { totalCount - UInt64(count) }
  public var remainingCounterValues: UInt64 { UInt64.max - totalCount }
  public var elements: [Element] {
    guard storage.count == capacity, next != 0 else { return storage }
    return Array(storage[next...]) + storage[..<next]
  }
  public mutating func append(_ element: Element) throws {
    guard remainingCounterValues > 0 else { throw Failure.counterOverflow }
    if storage.count < capacity { storage.append(element) } else { storage[next] = element }
    next = (next + 1) % capacity
    totalCount += 1
  }
}

extension RecentHistory: Sendable where Element: Sendable {}
