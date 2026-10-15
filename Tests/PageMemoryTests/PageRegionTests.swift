import PageMemory
import Testing

#if os(Linux) && canImport(Glibc)
  import Glibc
#elseif os(Linux) && canImport(Musl)
  import Musl
#endif

private func allZero(_ bytes: Span<UInt8>) -> Bool {
  for index in 0..<bytes.count { if bytes[index] != 0 { return false } }
  return true
}

@Suite struct PageRegionTests {
  @Test func roundingAndLimits() throws {
    let region = try PageRegion.allocate(byteCount: 1)
    #expect(region.byteCount == 1)
    #expect(region.mappedByteCount == region.pageSize)
    #expect(throws: PageMemoryError.invalidSize) { _ = try PageRegion.allocate(byteCount: 0) }
    #expect(throws: PageMemoryError.invalidSize) { _ = try PageRegion.allocate(byteCount: Int.max) }
    #expect(throws: PageMemoryError.limitExceeded) {
      _ = try PageRegion.allocate(byteCount: 2, maximumMappedBytes: 1)
    }
  }
  @Test func borrowedBytesAndIndependentOwners() throws {
    let sizing = try PageRegion.allocate(byteCount: 1)
    let step = sizing.pageSize
    var first = try PageRegion.allocate(byteCount: step + 1)
    let second = try PageRegion.allocate(byteCount: step + 1)
    try first.withMutableBytes { bytes in
      bytes[0] = 42
      bytes[step] = 91
    }
    #expect(try first.withBytes { $0[0] } == 42)
    #expect(try first.withBytes { $0[step] } == 91)
    #expect(try second.withBytes { $0[0] } == 0)
    try first.release()
    #expect(try second.withBytes { $0[step] } == 0)
  }
  @Test func discardRefusesAccessAndResetZeros() throws {
    let sizing = try PageRegion.allocate(byteCount: 1)
    let step = sizing.pageSize
    var region = try PageRegion.allocate(byteCount: step + 1)
    try region.withMutableBytes { bytes in
      bytes[0] = 42
      bytes[step] = 91
    }
    let report = try region.discardContents()
    #expect(report.advisedBytes == region.mappedByteCount)
    #expect(report.physicalReleasedBytes == nil)
    #expect(throws: PageMemoryError.contentsDiscarded) { _ = try region.withBytes { $0[0] } }
    #expect(throws: PageMemoryError.contentsDiscarded) { try region.withMutableBytes { $0[0] = 1 } }
    #expect(try region.discardContents().advisedBytes == 0)
    try region.resetToZero()
    #expect(try region.withBytes { $0[0] } == 0)
    #expect(try region.withBytes { $0[step] } == 0)
    try region.withMutableBytes { $0[0] = 12 }
    #expect(try region.withBytes { $0[0] } == 12)
  }
  @Test func actualResidencyAndRelease() throws {
    let sizing = try PageRegion.allocate(byteCount: 1)
    let step = sizing.pageSize
    var region = try PageRegion.allocate(
      byteCount: step * 1024 + 1, maximumMappedBytes: step * 1025)
    try region.withMutableBytes { bytes in
      for offset in stride(from: 0, to: bytes.count, by: step) { bytes[offset] = 17 }
    }
    #expect(try region.residentPageCount() > 0)
    _ = try region.discardContents()
    #if os(Linux)
      #expect(try region.residentPageCount() == 0)
    #endif
    try region.release()
    try region.release()
    let released = region.isReleased
    #expect(released)
    #expect(throws: PageMemoryError.unavailable) { _ = try region.residentPageCount() }
    #expect(throws: PageMemoryError.unavailable) { try region.resetToZero() }
  }
  @Test func callbackFailureValueDoesNotInvalidateOwnership() throws {
    enum Failure: Error { case rejected }
    var region = try PageRegion.allocate(byteCount: 4096)
    let result: Result<Int, Failure> = try region.withMutableBytes { bytes in
      bytes[0] = 73
      return .failure(.rejected)
    }
    if case .success = result { Issue.record("failure value lost") }
    #expect(try region.withBytes { $0[0] } == 73)
    try region.release()
  }
  @Test func throwingCallbacksPreserveErrorAndOwnership() throws {
    enum Rejected: Error, Equatable { case payload }
    var region = try PageRegion.allocate(byteCount: 1)
    #expect(throws: Rejected.payload) {
      try region.withWriteAccess { (bytes: inout MutableSpan<UInt8>) throws(Rejected) -> Void in
        bytes[0] = 73
        throw .payload
      }
    }
    #expect(try region.withBytes { $0[0] } == 73)
    #expect(throws: Rejected.payload) {
      try region.withReadAccess { (_: Span<UInt8>) throws(Rejected) -> Void in throw .payload }
    }
    try region.release()
  }
  @Test func callbackReturnsIndependentNoncopyableOwner() throws {
    struct Token: ~Copyable { let value: Int }
    var region = try PageRegion.allocate(byteCount: 1)
    let first = try region.withBytes { _ in Token(value: 73) }
    let second = try region.withMutableBytes { _ in Token(value: 91) }
    let values = (first.value, second.value)
    #expect(values.0 == 73 && values.1 == 91)
  }
  @Test func reusableAdviceCanCycleAndChangeStrategy() throws {
    let sizing = try PageRegion.allocate(byteCount: 1)
    var region = try PageRegion.allocate(byteCount: sizing.pageSize + 1)
    for strategy: ReclamationStrategy in [.reusable, .platformDefault, .reusable] {
      try region.withMutableBytes { bytes in
        bytes[0] = 73
        bytes[bytes.count - 1] = 91
      }
      let report = try region.discardContents(using: strategy)
      #expect(report.advisedBytes == region.mappedByteCount)
      #if canImport(Darwin)
        #expect(report.semantics == .lazyFree)
        #expect(report.usesReusableAccounting == (strategy == .reusable))
      #else
        #expect(report.semantics == .discardAndZeroOnDemand)
        #expect(!report.usesReusableAccounting)
      #endif
      #expect(throws: PageMemoryError.contentsDiscarded) { _ = try region.withBytes { $0[0] } }
      try region.resetToZero()
      #expect(try region.withBytes { $0[0] } == 0)
      #expect(try region.withBytes { $0[$0.count - 1] } == 0)
    }
    try region.release()
  }
  @Test func nativeSelfMemoryCountersAreAvailable() throws {
    let snapshot = try ProcessMemorySnapshot.capture()
    #expect(snapshot.residentBytes > 0)
    #if canImport(Darwin)
      #expect(snapshot.physicalFootprintBytes != nil)
    #else
      #expect(snapshot.physicalFootprintBytes == nil)
    #endif
  }
  @Test func reclaimableBackingRetiresAndReusesOnlyAfterInitialization() throws {
    var region = try PageRegion.allocate(byteCount: 262_145, backing: .reclaimable)
    let step = region.pageSize
    for _ in 0..<8 {
      try region.withMutableBytes { bytes in
        for index in stride(from: 0, to: bytes.count, by: step) { bytes[index] = 73 }
      }
      #expect(try region.residentPageCount() > 0)
      let report = try region.discardContents()
      #expect(report.advisedBytes == region.mappedByteCount)
      #expect(report.physicalReleasedBytes == nil)
      // EMPTY may retain busy pages; physical drops are measured in the controlled probe.
      #expect(throws: PageMemoryError.contentsDiscarded) { _ = try region.withBytes { $0[0] } }
      #if canImport(Darwin)
        #expect(try region.discardContents().advisedBytes == region.mappedByteCount)
      #else
        #expect(try region.discardContents().advisedBytes == 0)
      #endif
      try region.resetToZero()
      #expect(try region.withBytes { allZero($0) })
    }
    try region.release()
    try region.release()
    let released = region.isReleased
    #expect(released)
    #expect(throws: PageMemoryError.unavailable) { try region.eraseContents() }
  }
  @Test(arguments: [PageBacking.anonymous, .reclaimable])
  func explicitErasureAndNonblockingRefusal(backing: PageBacking) throws {
    var region = try PageRegion.allocate(byteCount: 262_145, backing: backing)
    try region.withMutableBytes { bytes in
      for index in 0..<bytes.count { bytes[index] = 91 }
    }
    #expect(throws: PageMemoryError.operationMayBlock) {
      try region.eraseContents(context: .nonblocking)
    }
    #expect(throws: PageMemoryError.operationMayBlock) {
      try region.release(context: .nonblocking)
    }
    #expect(try region.withBytes { $0[0] == 91 && $0[$0.count - 1] == 91 })
    try region.eraseContents()
    #expect(try region.withBytes { allZero($0) })
    try region.withMutableBytes {
      $0[0] = 73
      $0[$0.count - 1] = 91
    }
    try region.resetToZero()
    #expect(try region.withBytes { allZero($0) })
    _ = try region.discardContents(using: .reusable)
    try region.eraseContents()
    #expect(try region.withBytes { allZero($0) })
    try region.release()
  }
  #if canImport(Darwin)
    #if os(macOS)
      @Test(arguments: [1, 254, 255, 256, 511])
      func darwinDispositionIncludesEveryRoundedBatch(pages: Int) throws {
        let sizing = try PageRegion.allocate(byteCount: 1)
        let step = sizing.pageSize
        var region = try PageRegion.allocate(
          byteCount: (pages - 1) * step + 1, backing: .reclaimable)
        #expect(try region.residentPageCount() == 0)
        let cold = try region.darwinPageDispositionCounts()
        #expect(cold.pageCount == pages && cold.presentPages == 0 && cold.pagedOutPages == 0)
        #expect(try region.residentPageCount() == 0)
        try region.withMutableBytes { bytes in
          for index in stride(from: 0, to: bytes.count, by: step) { bytes[index] = 73 }
        }
        #expect(throws: PageMemoryError.operationMayBlock) {
          _ = try region.darwinPageDispositionCounts(context: .nonblocking)
        }
        let touched = try region.darwinPageDispositionCounts()
        #expect(touched.pageCount == pages)
        #expect(touched.presentPages + touched.pagedOutPages == pages)
        #expect(touched.pagedOutPages <= pages && touched.reusablePages <= pages)
        #expect(try region.withBytes { $0[0] == 73 && $0[$0.count - 1] == 73 })
        _ = try region.discardContents()
        let discarded = try region.darwinPageDispositionCounts()
        #expect(discarded.pageCount == pages)
        #expect(throws: PageMemoryError.contentsDiscarded) { _ = try region.withBytes { $0[0] } }
        try region.resetToZero()
        #expect(try region.withBytes { allZero($0) })
        try region.release()
        #expect(throws: PageMemoryError.unavailable) {
          _ = try region.darwinPageDispositionCounts()
        }
      }
      @Test func darwinDispositionTracksReusableLifecycle() throws {
        var region = try PageRegion.allocate(byteCount: 1_048_576)
        let step = region.pageSize
        try region.withMutableBytes { bytes in
          for index in stride(from: 0, to: bytes.count, by: step) { bytes[index] = 73 }
        }
        _ = try region.discardContents(using: .reusable)
        let advised = try region.darwinPageDispositionCounts()
        #expect(advised.reusablePages == advised.presentPages)
        try region.resetToZero()
        #expect(try region.darwinPageDispositionCounts().reusablePages == 0)
        try region.release()
      }
    #endif
    @Test func discardedRegionCanUpgradeReusableAccounting() throws {
      var region = try PageRegion.allocate(byteCount: 1)
      _ = try region.discardContents()
      let upgrade = try region.discardContents(using: .reusable)
      #expect(upgrade.advisedBytes == region.mappedByteCount && upgrade.usesReusableAccounting)
      let noop = try region.discardContents(using: .platformDefault)
      #expect(noop.advisedBytes == 0 && noop.usesReusableAccounting)
      try region.resetToZero()
      #expect(try region.withBytes { $0[0] } == 0)
    }
  #endif
  #if os(Linux)
    @Test(arguments: [false, true])
    func lockedPagesRecoverAfterAdviceFailure(partiallyLocked: Bool) throws {
      let sizing = try PageRegion.allocate(byteCount: 1)
      let step = sizing.pageSize
      var region = try PageRegion.allocate(byteCount: step * (partiallyLocked ? 2 : 1))
      let locked = try region.withMutableBytes { bytes in
        bytes[0] = 73
        bytes[bytes.count - 1] = 91
        return bytes.withUnsafeMutableBufferPointer { buffer in
          unsafe mlock(buffer.baseAddress!.advanced(by: partiallyLocked ? step : 0), step)
        }
      }
      try #require(locked == 0, "mlock failed with errno \(errno)")
      // The kernel refuses DONTNEED on locked pages. Unmapping also unlocks them.
      #expect(throws: PageMemoryError.systemCall(operation: .advise, code: EINVAL)) {
        _ = try region.discardContents()
      }
      #expect(throws: PageMemoryError.contentsDiscarded) { _ = try region.withBytes { $0[0] } }
      #expect(throws: PageMemoryError.contentsDiscarded) {
        try region.withMutableBytes { $0[0] = 1 }
      }
      try region.eraseContents()
      #expect(try region.withBytes { allZero($0) })
      try region.resetToZero()
      #expect(try region.withBytes { $0[0] } == 0)
      #expect(try region.withBytes { $0[$0.count - 1] } == 0)
      try region.release()
    }
  #endif
}
