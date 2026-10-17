import Foundation
import Testing

@testable import NativeGuestMemory

private func parse(_ text: String) throws -> GuestMemoryReading {
  try Array(text.utf8).withUnsafeBufferPointer { try GuestMemory.parse(meminfo: $0) }
}

private let meminfo = """
  MemTotal:       16384 kB
  MemFree:         1024 kB
  MemAvailable:    8192 kB
  Buffers:            0 kB
  """

@Test func meminfoParsesKilobytesIntoBytes() throws {
  let reading = try parse(meminfo + "\n")
  #expect(reading == GuestMemoryReading(total: 16_777_216, available: 8_388_608))
  #expect(reading.wireFields == "16777216 8388608")
  // A final line without a newline and tab or repeated blanks are still exact fields.
  #expect(try parse("MemAvailable:\t7  kB \nMemTotal: 7 kB").available == 7168)
}

@Test func meminfoAcceptsLargestBoundedValueAndIgnoresLookalikeKeys() throws {
  let largest = (1 << 40) - 1
  let reading = try parse(
    "XMemTotal: 1 kB\nMemTotalX: 1 kB\nMemTotal: \(largest) kB\nMemAvailable: 1 kB\n")
  #expect(reading.total == UInt64(largest) * 1024 && reading.available == 1024)
}

@Test(arguments: [
  "", "MemTotal: 1 kB\n", "MemAvailable: 1 kB\n",
  "MemTotal: 2 kB\nMemTotal: 2 kB\nMemAvailable: 1 kB\n",
  "MemTotal: 2 kB\nMemAvailable: 1 kB\nMemAvailable: 1 kB\n",
  "MemTotal: 0 kB\nMemAvailable: 0 kB\n",
  "MemTotal: 1 kB\nMemAvailable: 2 kB\n",
  "MemTotal: 1099511627776 kB\nMemAvailable: 1 kB\n",
  "MemTotal: 99999999999999999999999 kB\nMemAvailable: 1 kB\n",
  "MemTotal: 2 MB\nMemAvailable: 1 kB\n", "MemTotal: 2\nMemAvailable: 1 kB\n",
  "MemTotal: 2kB\nMemAvailable: 1 kB\n", "MemTotal:2 kB\nMemAvailable: 1 kB\n",
  "MemTotal: +2 kB\nMemAvailable: 1 kB\n", "MemTotal: -2 kB\nMemAvailable: 1 kB\n",
  "MemTotal: abc 2 kB\nMemAvailable: 1 kB\n", "MemTotal: 2 kB extra\nMemAvailable: 1 kB\n",
  "MemTotal: 2 kB\r\nMemAvailable: 1 kB\n", "MemTotal: 2 kb\nMemAvailable: 1 kB\n",
])
func malformedMeminfoIsRefused(_ text: String) {
  #expect(throws: GuestMemoryFailure.framing) { try parse(text) }
}

@Test(arguments: [
  ("OBS 1", UInt64(1), MemoryMonitorCommand.observe),
  ("OBS_REFRESH 7", UInt64(7), MemoryMonitorCommand.observeRefreshing),
  ("QUIT 18446744073709551615", UInt64.max, MemoryMonitorCommand.quit),
])
func requestsMatchOnlyTheirExactSequence(
  line: String, sequence: UInt64, expected: MemoryMonitorCommand
) {
  #expect(MemoryMonitorCommand(line: line, sequence: sequence) == expected)
  #expect(MemoryMonitorCommand(line: line, sequence: sequence &- 1) == nil)
}

@Test(arguments: [
  "", "OBS", "OBS ", "OBS 01", "OBS 1 ", " OBS 1", "obs 1", "OBS  1", "OBS +1", "OBS 1\r",
  "OBS_REFRESH", "OBS_REFRESH1", "QUIT", "QUIT 1 2", "VERIFY 1", "HOLD 1", "STATE 1 1",
])
func malformedRequestsAreRefused(_ line: String) {
  #expect(MemoryMonitorCommand(line: line, sequence: 1) == nil)
}

private let serviceStatus = """
  Name: monitor
  CapInh: 0000000000000000
  CapPrm: 0000000000000000
  CapEff: 0000000000000000
  CapBnd: 0000000000000000
  CapAmb: 0000000000000000
  NoNewPrivs: 1
  Threads: 1
  """

@Test func servicePrivilegeAdmissionUsesTheObservedKernelStatus() {
  #expect(throws: Never.self) {
    try Array(serviceStatus.utf8).withUnsafeBufferPointer {
      try GuestMemoryService.validateStatus($0)
    }
  }
}

@Test(arguments: [
  ("CapEff: 0000000000000000", "CapEff: 0000000000000001"),
  ("CapBnd: 0000000000000000", "CapBnd: 0000000000000001"),
  ("CapAmb: 0000000000000000", ""),
  ("NoNewPrivs: 1", "NoNewPrivs: 0"),
  ("NoNewPrivs: 1", "NoNewPrivs: 1\nNoNewPrivs: 1"),
  ("Threads: 1", "Threads: 2"),
])
func unsafeOrIncompleteServiceStatusIsRefused(old: String, replacement: String) {
  let text = serviceStatus.replacingOccurrences(of: old, with: replacement)
  #expect(throws: GuestMemoryService.Failure.privileges) {
    try Array(text.utf8).withUnsafeBufferPointer { try GuestMemoryService.validateStatus($0) }
  }
}
