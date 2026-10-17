import Testing

@testable import NativeLinuxVMM

@Test func scatteredCompletionsSurviveBoundedBatchesAndDeflateRevokesPendingWork() throws {
  var ledger = try BalloonPFNs(boot: 0x4000_0000..<0x6000_0000, dynamicBytes: 128 << 20)
  let base = UInt32(MemoryDevice.base >> 12)
  for extent in 0..<16 {
    let first = base + UInt32(extent * 512)
    #expect(try ledger.transfer(Array(first..<(first + 256)), inflate: true).isEmpty)
    #expect(try ledger.transfer(Array((first + 256)..<(first + 511)), inflate: true).isEmpty)
  }
  let lastPages = (0..<16).map { base + UInt32($0 * 512 + 511) }
  #expect(try ledger.transfer(lastPages, inflate: true) == Array(0..<16))
  #expect(ledger.fullyOwnedDynamicExtents == 16 && ledger.peakFullyOwnedDynamicExtents == 16)
  #expect(ledger.takeRecyclingBatch() == [0, 1, 2, 3])
  #expect(ledger.pendingRecyclingCount == 12)
  #expect(ledger.ownsExtent(5))
  let released = ledger.releaseOwned([lastPages[5]])
  #expect(released)
  #expect(ledger.pendingRecyclingCount == 11)
  #expect(ledger.fullyOwnedDynamicExtents == 15)
  #expect(!ledger.ownsExtent(5))
  #expect(ledger.takeRecyclingBatch() == [4, 6, 7, 8])
  #expect(try ledger.transfer([lastPages[5]], inflate: true) == [5])
  #expect(ledger.ownsExtent(5))
  #expect(ledger.fullyOwnedDynamicExtents == 16)
  #expect(ledger.takeRecyclingBatch() == [5, 9, 10, 11])
  #expect(ledger.takeRecyclingBatch() == [12, 13, 14, 15])
  #expect(ledger.takeRecyclingBatch().isEmpty)
  #expect(ledger.count == 16 * 512)
}

@Test func resetAndZeroRescueCannotReplayQueuedBackingReplacements() throws {
  var ledger = try BalloonPFNs(boot: 0x4000_0000..<0x6000_0000, dynamicBytes: 128 << 20)
  let base = UInt32(MemoryDevice.base >> 12)
  _ = try ledger.transfer(Array(base..<(base + 256)), inflate: true)
  _ = try ledger.transfer(Array((base + 256)..<(base + 512)), inflate: true)
  #expect(ledger.pendingRecyclingCount == 1)
  ledger.cancelRecycling()
  #expect(ledger.takeRecyclingBatch().isEmpty && ledger.count == 512)
  _ = try ledger.transfer([base], inflate: false)
  _ = try ledger.transfer([base], inflate: true)
  #expect(ledger.pendingRecyclingCount == 1)
  try ledger.reset()
  #expect(ledger.takeRecyclingBatch().isEmpty && ledger.count == 0 && ledger.epoch == 2)
  #expect(!ledger.ownsExtent(0) && !ledger.ownsExtent(-1) && !ledger.ownsExtent(64))
  #expect(ledger.fullyOwnedDynamicExtents == 0 && ledger.peakFullyOwnedDynamicExtents == 1)
}

@Test func recyclingBudgetSpansPollingAndMMIOUntilTheNextStoppedEpoch() throws {
  var window = RecyclingWindow()
  #expect(try window.admit(epoch: 1, pending: 2) == 2)
  #expect(try window.admit(epoch: 1, pending: 1000) == 2)
  #expect(try window.admit(epoch: 1, pending: 1000) == 0)
  #expect(try window.admit(epoch: 2, pending: 0) == 0)
  #expect(try window.admit(epoch: 2, pending: 1000) == 4)
  #expect(throws: DeviceFailure.self) { try window.admit(epoch: 1, pending: 1) }
  #expect(throws: DeviceFailure.self) { try window.admit(epoch: 3, pending: -1) }
  #expect(try window.admit(epoch: 2, pending: 1) == 0)
}

@Test func positiveSettlementWaitsForBackingAttemptsAndZeroRescueDoesNot() {
  let positive = NativeBalloonState(
    epoch: 1, ready: true, targetBytes: 128 << 20, actualBytes: 128 << 20,
    ownedBytes: 128 << 20, quarantined: false, requestGeneration: 1, appliedGeneration: 1,
    zeroTargetObserved: false, pendingRecyclingExtents: 1)
  #expect(!positive.settled)
  let zero = NativeBalloonState(
    epoch: 1, ready: true, targetBytes: 0, actualBytes: 0, ownedBytes: 0,
    quarantined: false, requestGeneration: 2, appliedGeneration: 2,
    zeroTargetObserved: true, pendingRecyclingExtents: 1)
  #expect(zero.settled)
}

@Test func cachedCompleteExtentCountsMatchAnIndependentPFNSetAcrossMutation() throws {
  var ledger = try BalloonPFNs(boot: 0x4000_0000..<0x6000_0000, dynamicBytes: 128 << 20)
  let base = UInt32(MemoryDevice.base >> 12)
  var model = Set(base..<(base + 2048))
  for first in stride(from: base, to: base + 2048, by: 256) {
    _ = try ledger.transfer(Array(first..<(first + 256)), inflate: true)
  }
  var random: UInt64 = 19
  for _ in 0..<1000 {
    random = random &* 6_364_136_223_846_793_005 &+ 1
    let pfn = base + UInt32(random >> 32) % 2048
    if model.remove(pfn) != nil {
      let released = ledger.releaseOwned([pfn])
      #expect(released)
    } else {
      _ = try ledger.transfer([pfn], inflate: true)
      model.insert(pfn)
    }
    let complete = (0..<4).filter { index in
      (0..<512).allSatisfy { model.contains(base + UInt32(index * 512 + $0)) }
    }.count
    #expect(ledger.fullyOwnedDynamicExtents == UInt32(complete))
    #expect(ledger.count == model.count && ledger.peakFullyOwnedDynamicExtents == 4)
  }
}

@Test func replacementWithoutAPendingAcknowledgementRequiresPersistentOwnership() throws {
  let memory = MemoryDevice(held: false)
  #expect(throws: DeviceFailure.self) {
    try memory.recycleOwned([], quiescence: (true, 1, 1), acknowledgmentPending: false)
  }
  #expect(throws: DeviceFailure.self) {
    try memory.recycleOwned(
      [], quiescence: (true, 1, 1), balloonEpoch: 0, acknowledgmentPending: false)
  }
  try memory.recycleOwned([], quiescence: (true, 1, 1))
  try memory.recycleOwned(
    [], quiescence: (true, 1, 1), balloonEpoch: 1, acknowledgmentPending: false)
}
