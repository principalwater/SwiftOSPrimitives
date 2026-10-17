import BoundedMemory
import Foundation

/// Complete, naturally aligned dynamic units currently owned by the stock balloon bitmap.
/// Ownership only: metadata pins, residency and backing are unknown, so these are upper bounds.
struct BalloonOwnershipCoverage: Equatable, Sendable {
  var units16KiB: UInt32 = 0
  var units64KiB: UInt32 = 0
  var units128KiB: UInt32 = 0
  var units512KiB: UInt32 = 0
  var units2MiB: UInt32 = 0
}

extension BalloonOwnershipCoverage {
  /// One allocation-free pass over bitmap words of 64 PFNs each. The slice starts at the dynamic
  /// base, which is 2 MiB aligned, so every eight words are one backing object and unit alignment
  /// is exact. Boot words are never part of the slice.
  init(dynamicWords words: ArraySlice<UInt64>) {
    self.init()
    for object in 0..<(words.count / 8) {
      var complete: UInt8 = 0
      for lane in 0..<8 {
        var run = words[words.startIndex + object * 8 + lane]
        guard run != 0 else { continue }
        if run == .max { complete |= 1 << lane }
        // Progressive AND: the lowest bit of an aligned group survives only if every page does.
        run &= run >> 1
        run &= run >> 2
        units16KiB += UInt32((run & 0x1111_1111_1111_1111).nonzeroBitCount)
        run &= run >> 4
        run &= run >> 8
        units64KiB += UInt32((run & 0x0001_0001_0001_0001).nonzeroBitCount)
        run &= run >> 16
        units128KiB += UInt32((run & 0x0000_0001_0000_0001).nonzeroBitCount)
      }
      // Two aligned complete words are 512 KiB; all eight are the 2 MiB backing object.
      units512KiB += UInt32((complete & (complete >> 1) & 0x55).nonzeroBitCount)
      if complete == .max { units2MiB += 1 }
    }
  }
}

/// One fixed-size reading taken after a positive balloon target was published as zero.
struct BalloonCoverageSample: Sendable {
  let epoch: UInt64
  let previousTargetPFNs: UInt32
  let ownedPFNs: UInt32
  let ownedDynamicPFNs: UInt32
  let coverage: BalloonOwnershipCoverage
  /// Monotonic duration of the bitmap scan alone.
  let elapsed: Duration

  /// Rendered only for final saved evidence.
  var record: [String: UInt64] {
    let parts = elapsed.components
    // One scan is short and the clock is monotonic; saturate instead of trapping in a diagnostic.
    let seconds = min(UInt64(clamping: parts.seconds), UInt64.max / 1_000_000_000 - 1)
    return [
      "epoch": epoch, "previousTargetPFNs": UInt64(previousTargetPFNs),
      "ownedPFNs": UInt64(ownedPFNs), "ownedDynamicPFNs": UInt64(ownedDynamicPFNs),
      "fullyOwned16KiBUnits": UInt64(coverage.units16KiB),
      "fullyOwned64KiBUnits": UInt64(coverage.units64KiB),
      "fullyOwned128KiBUnits": UInt64(coverage.units128KiB),
      "fullyOwned512KiBUnits": UInt64(coverage.units512KiB),
      "fullyOwned2MiBUnits": UInt64(coverage.units2MiB),
      "samplingNanoseconds": seconds * 1_000_000_000
        + UInt64(clamping: parts.attoseconds / 1_000_000_000),
    ]
  }
}

/// The newest sixteen readings, appended only when a positive target returns to zero.
/// It is confined to the coordinator that owns the ledger and has no timer or second reader.
struct BalloonCoverageJournal {
  private var history = RecentHistory<BalloonCoverageSample>(capacity: 16)
  /// Diagnostic append failures, reported apart from every device error.
  private(set) var failures: UInt64 = 0
  var samples: [BalloonCoverageSample] { history.elements }

  /// Call only after the zero target, recycling cancellation, generation and interrupt are
  /// published. The ledger is read, never written, and no failure here can throw into the rescue.
  mutating func recordZeroTransition(
    from previous: UInt32, to target: UInt32, ledger: BalloonPFNs
  ) {
    guard previous != 0, target == 0 else { return }
    let began = ContinuousClock.now
    let coverage = ledger.ownedCoverage()
    let elapsed = began.duration(to: ContinuousClock.now)
    do {
      try history.append(
        BalloonCoverageSample(
          epoch: ledger.epoch, previousTargetPFNs: previous, ownedPFNs: ledger.count,
          ownedDynamicPFNs: ledger.dynamicCount, coverage: coverage, elapsed: elapsed))
    } catch {
      if failures < .max { failures += 1 }
    }
  }

  private static let scope =
    "Fully owned aligned dynamic PFN units when a positive target first became zero, after "
    + "publication and before the next packet; not the pulse peak. Ownership upper bound only: "
    + "metadata pins, residency, backing and physical release are not evaluated. A pulse that "
    + "ended by fatal stop or kill has no sample; an absent sample is never zero coverage."

  /// Final saved evidence only. Nothing here is reclaimable RAM or a physical release.
  func evidence(pulseActive: Bool) -> [String: Any] {
    [
      "scope": Self.scope, "samples": samples.map(\.record),
      "samplesTotal": history.totalCount, "samplesDropped": history.droppedCount,
      "recordFailures": failures, "pulseActiveAtEvidence": pulseActive,
      "metadataPinsFiltered": false, "residencyFiltered": false,
      "physicalReleasedBytes": NSNull(),
    ]
  }
}
