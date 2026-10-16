import Testing

@testable import BoundedMemory

@Test(arguments: [1, 2, 32, 512, 1025])
func recentHistoryRetainsOrderAcrossRepeatedWraps(capacity: Int) throws {
  var history = RecentHistory<Int>(capacity: capacity)
  let count = capacity * 3 + 7
  for value in 0..<count { try history.append(value) }
  #expect(history.elements == Array((count - capacity)..<count))
  #expect(history.count == capacity)
  #expect(history.totalCount == UInt64(count))
  #expect(history.droppedCount == UInt64(count - capacity))
}

@Test func historySnapshotIsStableWhileOwnerContinues() throws {
  var history = RecentHistory<Int>(capacity: 2)
  try history.append(7)
  try history.append(8)
  let previous = history.elements
  try history.append(9)
  #expect(previous == [7, 8])
  #expect(history.elements == [8, 9])
}
