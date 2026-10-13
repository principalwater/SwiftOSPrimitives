import PageMemory
import Testing

#if os(Linux) && canImport(Glibc)
  import Glibc
#elseif os(Linux) && canImport(Musl)
  import Musl
#endif

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
  #if os(Linux)
    @Test func lockedPagesRecoverAfterAdviceFailure() throws {
      let sizing = try PageRegion.allocate(byteCount: 1)
      var region = try PageRegion.allocate(byteCount: sizing.pageSize)
      let locked = try region.withMutableBytes { bytes in
        bytes[0] = 73
        bytes[bytes.count - 1] = 91
        return bytes.withUnsafeMutableBufferPointer { buffer in
          unsafe mlock(buffer.baseAddress, buffer.count)
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
      try region.resetToZero()
      #expect(try region.withBytes { $0[0] } == 0)
      #expect(try region.withBytes { $0[$0.count - 1] } == 0)
      try region.release()
    }
  #endif
}
