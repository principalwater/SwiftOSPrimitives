import BoundedMemory
import Testing

struct BalloonBudgetTests {
  @Test func conservativeRoundingAndBoundedSteps() throws {
    let budget = try #require(
      BalloonBudget(
        installedBytes: 65536, minimumResidentBytes: 16384, granuleBytes: 4096,
        maximumStepBytes: 8192))
    #expect(budget.target(observedResidentBytes: 65536, requestedResidentBytes: 1) == 57344)
    #expect(budget.target(observedResidentBytes: 16384, requestedResidentBytes: 65536) == 24576)
    #expect(budget.target(observedResidentBytes: 32768, requestedResidentBytes: 24577) == 28672)
    #expect(budget.target(observedResidentBytes: 16384, requestedResidentBytes: 1) == 16384)
    #expect(budget.target(observedResidentBytes: 32768, requestedResidentBytes: 32768) == 32768)
    for invalid in [UInt64(0), 16383, 65537, UInt64.max] {
      #expect(budget.target(observedResidentBytes: invalid, requestedResidentBytes: 32768) == nil)
    }
    for invalid in [UInt64(0), 65537, UInt64.max] {
      #expect(budget.target(observedResidentBytes: 32768, requestedResidentBytes: invalid) == nil)
    }
  }

  @Test func geometryAndIntegerBoundary() throws {
    for (installed, floor, granule, step) in [
      (0, 4096, 4096, 4096), (65537, 4096, 4096, 4096), (65536, 0, 4096, 4096),
      (65536, 65537, 4096, 4096), (65536, 4097, 4096, 4096), (65536, 4096, 0, 4096),
      (65536, 4096, 8191, 4096), (65536, 4096, 2048, 4096),
      (65536, 4096, 4096, 0), (65536, 4096, 4096, 4097),
    ] {
      #expect(
        BalloonBudget(
          installedBytes: UInt64(installed), minimumResidentBytes: UInt64(floor),
          granuleBytes: UInt64(granule), maximumStepBytes: UInt64(step)) == nil)
    }
    let top = UInt64.max - 4095
    let budget = try #require(
      BalloonBudget(
        installedBytes: top, minimumResidentBytes: 4096, granuleBytes: 4096,
        maximumStepBytes: top))
    #expect(budget.target(observedResidentBytes: 4096, requestedResidentBytes: top - 1) == top)
    #expect(budget.target(observedResidentBytes: top, requestedResidentBytes: 1) == 4096)
  }
}
