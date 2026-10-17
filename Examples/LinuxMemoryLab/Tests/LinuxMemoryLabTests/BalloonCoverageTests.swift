import Foundation
import Testing

@testable import NativeLinuxVMM

// The dynamic base is 2 MiB aligned, so unit alignment is the same in PFNs and dynamic indexes.
private let dynamicBase = UInt32(MemoryDevice.base >> 12)
private let bootBase: UInt32 = 0x4_0000  // GPA 0x4000_0000
private let lastBootBase: UInt32 = 0xF_FE00  // GPA 0xFFE0_0000, the final 2 MiB below 4 GiB
private let maximumDynamicPages = (3 << 30) / 4096

private func coverageLedger(
  boot: Range<UInt64> = 0x4000_0000..<0x4020_0000, dynamicBytes: UInt64 = 128 << 20
) throws -> BalloonPFNs {
  try BalloonPFNs(boot: boot, dynamicBytes: dynamicBytes)
}

private func coveragePFNs(_ pages: Range<Int>, from base: UInt32 = dynamicBase) -> [UInt32] {
  pages.map { base + UInt32($0) }
}

/// The real bounded packet path: transfer accepts at most 256 unique PFNs per call.
private func coverageMove(_ pfns: [UInt32], inflate: Bool, _ ledger: inout BalloonPFNs) throws {
  for start in stride(from: 0, to: pfns.count, by: 256) {
    _ = try ledger.transfer(Array(pfns[start..<min(start + 256, pfns.count)]), inflate: inflate)
  }
}

/// Independent reference: a unit counts only when every PFN inside it is in the owned set.
private func coverageReference(_ owned: Set<UInt32>) -> BalloonOwnershipCoverage {
  func units(_ pages: UInt32) -> UInt32 {
    let touched = Set(owned.map { ($0 - dynamicBase) / pages })
    let complete = touched.filter { unit in
      (0..<pages).allSatisfy { owned.contains(dynamicBase + unit * pages + $0) }
    }
    return UInt32(complete.count)
  }
  return BalloonOwnershipCoverage(
    units16KiB: units(4), units64KiB: units(16), units128KiB: units(32),
    units512KiB: units(128), units2MiB: units(512))
}

private func coverageState(_ ledger: BalloonPFNs) -> [UInt64] {
  [
    UInt64(ledger.count), UInt64(ledger.dynamicCount), ledger.epoch,
    UInt64(ledger.fullyOwnedDynamicExtents), UInt64(ledger.peakFullyOwnedDynamicExtents),
    UInt64(ledger.pendingRecyclingCount),
  ]
}

/// Deterministic runs and gaps of mixed lengths, so units straddle every alignment boundary.
private func scatteredPages(seed: UInt64, in window: Range<Int>) -> Set<UInt32> {
  var state = seed
  func next(_ bound: Int) -> Int {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Int(state >> 33) % bound
  }
  var owned: Set<UInt32> = []
  var page = window.lowerBound + next(40)
  while page < window.upperBound {
    let long = next(2) == 0
    let length = 1 + next(long ? 1500 : 40)
    for index in page..<min(page + length, window.upperBound) {
      owned.insert(dynamicBase + UInt32(index))
    }
    page += length + 1 + next(long ? 40 : 300)
  }
  return owned
}

struct BalloonCoverageRun: Sendable {
  let start: Int
  let length: Int
  /// Units at 16 KiB, 64 KiB, 128 KiB, 512 KiB and 2 MiB, counted by hand.
  let units: [UInt32]
  var expected: BalloonOwnershipCoverage {
    BalloonOwnershipCoverage(
      units16KiB: units[0], units64KiB: units[1], units128KiB: units[2],
      units512KiB: units[3], units2MiB: units[4])
  }
}

let balloonCoverageRuns = [
  BalloonCoverageRun(start: 0, length: 32, units: [8, 2, 1, 0, 0]),
  BalloonCoverageRun(start: 16, length: 32, units: [8, 2, 0, 0, 0]),
  BalloonCoverageRun(start: 2, length: 20, units: [4, 0, 0, 0, 0]),
  BalloonCoverageRun(start: 1, length: 63, units: [15, 3, 1, 0, 0]),
  BalloonCoverageRun(start: 60, length: 8, units: [2, 0, 0, 0, 0]),
  BalloonCoverageRun(start: 3, length: 1, units: [0, 0, 0, 0, 0]),
  BalloonCoverageRun(start: 64, length: 128, units: [32, 8, 4, 0, 0]),
  BalloonCoverageRun(start: 128, length: 128, units: [32, 8, 4, 1, 0]),
  BalloonCoverageRun(start: 448, length: 128, units: [32, 8, 4, 0, 0]),
  BalloonCoverageRun(start: 256, length: 512, units: [128, 32, 16, 4, 0]),
  BalloonCoverageRun(start: 512, length: 512, units: [128, 32, 16, 4, 1]),
]

@Test func emptyAndFullLedgersCountNoUnitsOrEveryAlignedUnit() throws {
  var ledger = try coverageLedger()
  #expect(ledger.ownedCoverage() == BalloonOwnershipCoverage())
  let all = coveragePFNs(0..<32768)
  try coverageMove(all, inflate: true, &ledger)
  #expect(
    ledger.ownedCoverage() == BalloonOwnershipCoverage(
      units16KiB: 8192, units64KiB: 2048, units128KiB: 1024, units512KiB: 256, units2MiB: 64))
  #expect(ledger.ownedCoverage() == coverageReference(Set(all)))
  #expect(ledger.ownedCoverage().units2MiB == ledger.fullyOwnedDynamicExtents)
  try coverageMove(all, inflate: false, &ledger)
  #expect(ledger.count == 0 && ledger.ownedCoverage() == BalloonOwnershipCoverage())
}

@Test(arguments: [0, 3, 4, 31, 32, 127, 128, 511, 512, 12_345, 32_767])
func oneMissingPFNRemovesExactlyOneUnitAtEveryGranule(_ page: Int) throws {
  var ledger = try coverageLedger()
  let all = coveragePFNs(0..<32768)
  var owned = Set(all)
  try coverageMove(all, inflate: true, &ledger)
  let missing = dynamicBase + UInt32(page)
  let released = ledger.releaseOwned([missing])
  owned.remove(missing)
  #expect(released)
  #expect(
    ledger.ownedCoverage() == BalloonOwnershipCoverage(
      units16KiB: 8191, units64KiB: 2047, units128KiB: 1023, units512KiB: 255, units2MiB: 63))
  #expect(ledger.ownedCoverage() == coverageReference(owned))
  #expect(ledger.fullyOwnedDynamicExtents == 63)
}

@Test(arguments: balloonCoverageRuns)
func unalignedRunsCountOnlyTheUnitsEntirelyInsideThem(_ run: BalloonCoverageRun) throws {
  var ledger = try coverageLedger()
  let pfns = coveragePFNs(run.start..<(run.start + run.length))
  try coverageMove(pfns, inflate: true, &ledger)
  #expect(ledger.ownedCoverage() == run.expected)
  #expect(ledger.ownedCoverage() == coverageReference(Set(pfns)))
}

@Test(arguments: [UInt64(1), 7, 19])
func scatteredPatternsMatchTheReferenceAcrossInflateAndDeflateChurn(_ seed: UInt64) throws {
  var ledger = try coverageLedger(dynamicBytes: 32 << 20)
  var owned = scatteredPages(seed: seed, in: 0..<8192)
  try coverageMove(owned.sorted(), inflate: true, &ledger)
  #expect(ledger.dynamicCount == UInt32(owned.count))
  #expect(ledger.ownedCoverage() == coverageReference(owned))
  #expect(ledger.ownedCoverage().units16KiB > 0)
  var random = seed
  for _ in 0..<12 {
    random = random &* 6_364_136_223_846_793_005 &+ 1
    let pfn = dynamicBase + UInt32(random >> 33) % 8192
    if owned.remove(pfn) != nil {
      let released = ledger.releaseOwned([pfn])
      #expect(released)
    } else {
      _ = try ledger.transfer([pfn], inflate: true)
      owned.insert(pfn)
    }
    #expect(ledger.ownedCoverage() == coverageReference(owned))
    #expect(ledger.ownedCoverage().units2MiB == ledger.fullyOwnedDynamicExtents)
  }
}

@Test func bootOwnershipNeverCountsAsDynamicCoverage() throws {
  var ledger = try coverageLedger(boot: 0x4000_0000..<0x4040_0000)
  try coverageMove(coveragePFNs(0..<1024, from: bootBase), inflate: true, &ledger)
  #expect(ledger.count == 1024 && ledger.dynamicCount == 0)
  #expect(ledger.ownedCoverage() == BalloonOwnershipCoverage())
  // The first dynamic object follows the last boot word in the bitmap; neither may leak across.
  try coverageMove(coveragePFNs(0..<512), inflate: true, &ledger)
  #expect(ledger.count == 1536 && ledger.dynamicCount == 512)
  #expect(
    ledger.ownedCoverage() == BalloonOwnershipCoverage(
      units16KiB: 128, units64KiB: 32, units128KiB: 16, units512KiB: 4, units2MiB: 1))
  #expect(ledger.ownedCoverage().units2MiB == ledger.fullyOwnedDynamicExtents)
}

@Test func deflateAndResetShrinkCoverageToTheCurrentLedgerOnly() throws {
  var ledger = try coverageLedger()
  let all = coveragePFNs(0..<2048)  // Four 2 MiB objects.
  var owned = Set(all)
  try coverageMove(all, inflate: true, &ledger)
  #expect(ledger.ownedCoverage().units2MiB == 4)
  let middle = coveragePFNs(512..<1536)
  try coverageMove(middle, inflate: false, &ledger)
  owned.subtract(middle)
  #expect(ledger.ownedCoverage() == coverageReference(owned))
  #expect(ledger.ownedCoverage().units2MiB == 2 && ledger.fullyOwnedDynamicExtents == 2)
  // A mixed deflate packet still releases the PFNs it owns before it is refused.
  let released = ledger.releaseOwned([dynamicBase + 5, dynamicBase + 600])
  owned.remove(dynamicBase + 5)
  #expect(!released)
  #expect(ledger.ownedCoverage() == coverageReference(owned))
  #expect(ledger.ownedCoverage().units2MiB == 1)
  let epoch = ledger.epoch
  try ledger.reset()
  #expect(ledger.epoch == epoch + 1 && ledger.count == 0)
  #expect(ledger.ownedCoverage() == BalloonOwnershipCoverage())
  let replay = coveragePFNs(0..<256)
  try coverageMove(replay, inflate: true, &ledger)
  #expect(ledger.ownedCoverage() == coverageReference(Set(replay)))
}

@Test func measuringCoverageNeverMutatesOwnershipOrQueuedRecycling() throws {
  var ledger = try coverageLedger()
  try coverageMove(coveragePFNs(0..<1536), inflate: true, &ledger)
  let before = coverageState(ledger)
  #expect(ledger.pendingRecyclingCount == 3)
  let frozen = ledger  // A non-mutating read compiles against an immutable copy.
  for _ in 0..<3 { _ = frozen.ownedCoverage() }
  #expect(coverageState(ledger) == before)
  #expect(ledger.takeRecyclingBatch() == [0, 1, 2])
}

@Test(.timeLimit(.minutes(1)))
func maximumGeometryCountsFullOwnershipAndTheFinalPFNExactly() throws {
  var ledger = try BalloonPFNs(boot: 0x4000_0000..<0x1_0000_0000, dynamicBytes: 3 << 30)
  // The last boot object is adjacent to the first dynamic word in the bitmap.
  try coverageMove(coveragePFNs(0..<512, from: lastBootBase), inflate: true, &ledger)
  #expect(ledger.count == 512 && ledger.dynamicCount == 0)
  #expect(ledger.ownedCoverage() == BalloonOwnershipCoverage())
  try coverageMove(coveragePFNs(0..<maximumDynamicPages), inflate: true, &ledger)
  #expect(ledger.dynamicCount == 786_432 && ledger.fullyOwnedDynamicExtents == 1_536)
  #expect(
    ledger.ownedCoverage() == BalloonOwnershipCoverage(
      units16KiB: 196_608, units64KiB: 49_152, units128KiB: 24_576,
      units512KiB: 6_144, units2MiB: 1_536))
  let released = ledger.releaseOwned([dynamicBase + 786_431])
  #expect(released)
  #expect(
    ledger.ownedCoverage() == BalloonOwnershipCoverage(
      units16KiB: 196_607, units64KiB: 49_151, units128KiB: 24_575,
      units512KiB: 6_143, units2MiB: 1_535))
  try ledger.reset()
  #expect(ledger.epoch == 2 && ledger.ownedCoverage() == BalloonOwnershipCoverage())
}

@Test(.timeLimit(.minutes(1)))
func scatteredPagesAtBothEndsOfMaximumGeometryMatchTheReference() throws {
  var ledger = try BalloonPFNs(boot: 0x4000_0000..<0x1_0000_0000, dynamicBytes: 3 << 30)
  let tail = (maximumDynamicPages - 4096)..<maximumDynamicPages
  var owned = scatteredPages(seed: 11, in: 0..<4096)
  owned.formUnion(scatteredPages(seed: 13, in: tail))
  owned.formUnion(coveragePFNs((maximumDynamicPages - 512)..<maximumDynamicPages))
  try coverageMove(owned.sorted(), inflate: true, &ledger)
  let expected = coverageReference(owned)
  #expect(ledger.ownedCoverage() == expected)
  #expect(expected.units2MiB >= 1 && expected.units16KiB >= 128)
  #expect(ledger.dynamicCount == UInt32(owned.count))
  #expect(ledger.ownedCoverage().units2MiB == ledger.fullyOwnedDynamicExtents)
}

@Test func journalRecordsOnlyAPositiveToZeroTransitionAndLeavesTheLedgerUntouched() throws {
  var ledger = try coverageLedger()
  let owned = coveragePFNs(0..<1024)
  try coverageMove(owned, inflate: true, &ledger)
  let before = coverageState(ledger)
  var journal = BalloonCoverageJournal()
  // Idle zero, first positive target, and positive retargets are not revocations.
  for (previous, target): (UInt32, UInt32) in [(0, 0), (0, 4096), (4096, 8192), (8192, 4096)] {
    journal.recordZeroTransition(from: previous, to: target, ledger: ledger)
  }
  #expect(journal.samples.isEmpty)
  journal.recordZeroTransition(from: 32768, to: 0, ledger: ledger)
  let sample = try #require(journal.samples.first)
  #expect(journal.samples.count == 1 && journal.failures == 0)
  #expect(sample.previousTargetPFNs == 32768 && sample.epoch == ledger.epoch)
  #expect(sample.ownedPFNs == 1024 && sample.ownedDynamicPFNs == 1024)
  #expect(sample.coverage == coverageReference(Set(owned)))
  #expect(sample.elapsed >= .zero)
  #expect(coverageState(ledger) == before)
}

@Test func journalKeepsTheNewestSixteenSamplesAndCountsWhatItDropped() throws {
  let ledger = try coverageLedger()
  var journal = BalloonCoverageJournal()
  for target in 1...20 {
    journal.recordZeroTransition(from: UInt32(target), to: 0, ledger: ledger)
  }
  #expect(journal.samples.map(\.previousTargetPFNs) == (5...20).map { UInt32($0) })
  let evidence = journal.evidence(pulseActive: false)
  #expect(evidence["samplesTotal"] as? UInt64 == 20 && evidence["samplesDropped"] as? UInt64 == 4)
  #expect((evidence["samples"] as? [[String: UInt64]])?.count == 16)
}

@Test func evidenceIsValidJSONAndNeverClaimsPhysicalReleaseOrFiltering() throws {
  var ledger = try coverageLedger()
  try coverageMove(coveragePFNs(0..<512), inflate: true, &ledger)
  var journal = BalloonCoverageJournal()
  // A pulse still active at the end has no sample; absence is not a fabricated zero reading.
  let active = journal.evidence(pulseActive: true)
  #expect(JSONSerialization.isValidJSONObject(active))
  #expect((active["samples"] as? [[String: UInt64]])?.isEmpty == true)
  #expect(active["samplesTotal"] as? UInt64 == 0)
  #expect(active["pulseActiveAtEvidence"] as? Bool == true)
  journal.recordZeroTransition(from: 512, to: 0, ledger: ledger)
  let evidence = journal.evidence(pulseActive: false)
  try #require(JSONSerialization.isValidJSONObject(evidence))
  let data = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
  let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  let evidenceKeys: Set<String> = [
    "scope", "samples", "samplesTotal", "samplesDropped", "recordFailures",
    "pulseActiveAtEvidence", "metadataPinsFiltered", "residencyFiltered",
    "physicalReleasedBytes",
  ]
  #expect(Set(decoded.keys) == evidenceKeys)
  #expect(decoded["physicalReleasedBytes"] is NSNull)
  #expect(decoded["metadataPinsFiltered"] as? Bool == false)
  #expect(decoded["residencyFiltered"] as? Bool == false)
  #expect((decoded["scope"] as? String)?.contains("upper bound") == true)
  let samples = try #require(decoded["samples"] as? [[String: Any]])
  let sample = try #require(samples.first)
  let sampleKeys: Set<String> = [
    "epoch", "previousTargetPFNs", "ownedPFNs", "ownedDynamicPFNs", "fullyOwned16KiBUnits",
    "fullyOwned64KiBUnits", "fullyOwned128KiBUnits", "fullyOwned512KiBUnits",
    "fullyOwned2MiBUnits", "samplingNanoseconds",
  ]
  #expect(Set(sample.keys) == sampleKeys)
  #expect(sample["fullyOwned2MiBUnits"] as? UInt64 == 1)
  #expect(sample["ownedDynamicPFNs"] as? UInt64 == 512)
  #expect(sample["previousTargetPFNs"] as? UInt64 == 512)
}

@Test func samplingDurationRendersAsSaturatingNanoseconds() {
  func rendered(_ elapsed: Duration) -> UInt64? {
    BalloonCoverageSample(
      epoch: 1, previousTargetPFNs: 1, ownedPFNs: 0, ownedDynamicPFNs: 0,
      coverage: BalloonOwnershipCoverage(), elapsed: elapsed
    ).record["samplingNanoseconds"]
  }
  #expect(rendered(.zero) == 0)
  #expect(rendered(.nanoseconds(1_500)) == 1_500)
  #expect(rendered(.seconds(2) + .nanoseconds(7)) == 2_000_000_007)
  #expect(rendered(.nanoseconds(-5)) == 0)
  #expect((rendered(.seconds(1 << 40)) ?? 0) > 1 << 62)
}
