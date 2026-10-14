import Foundation

enum ComparisonFailure: Error {
  case arguments, format, observation
}

func inspectComparison() throws {
  guard CommandLine.arguments.count == 2 else { throw ComparisonFailure.arguments }
  let file = URL(fileURLWithPath: CommandLine.arguments[1])
  let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
  guard let size = attributes[.size] as? NSNumber, size.intValue <= 131_072 else {
    throw ComparisonFailure.format
  }
  let text = try String(contentsOf: file, encoding: .utf8)
  var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
  guard lines.last == "" else { throw ComparisonFailure.format }
  lines.removeLast()
  let numbers = try lines.map { line -> UInt64 in
    guard let value = UInt64(line) else { throw ComparisonFailure.format }
    return value
  }
  guard numbers.count == 637, numbers[0] == 2,
    numbers[1] > 0, numbers[2] > 0, numbers[3] == 524_296,
    numbers[4] < 64, numbers[4] % 8 == 0
  else { throw ComparisonFailure.format }
  let clockPairs = numbers[5..<37].sorted()
  print("clockPairMedianTicks=\(clockPairs[15]), timebase=\(numbers[1])/\(numbers[2])")
  print("capacity,mode,iterations,p50BatchMeanNs,p95BatchMeanNs,p99BatchMeanNs,digest,generation")
  for (capacityIndex, capacity) in [128, 1024, 4096, 16384, 65536].enumerated() {
    for mode in 0..<3 {
      let row = Array(
        numbers[(37 + (capacityIndex * 3 + mode) * 40)..<(77 + (capacityIndex * 3 + mode) * 40)])
      let iterations = mode == 0 ? 256 : mode == 1 ? 32 : 16
      let free = mode == 0 ? 12 : mode == 1 ? 0 : capacity / 2
      let digest = 32 * (iterations * (iterations - 1) / 2 + iterations * free)
      let generation = mode == 0 ? 34 * iterations * 3 : mode == 1 ? 1 : 4
      guard row[0] == UInt64(capacity), row[1] == UInt64(mode),
        row[2] == UInt64(iterations), row[6] == UInt64(digest),
        row[7] == UInt64(generation)
      else { throw ComparisonFailure.observation }
      let rawTicks = row[8..<40].sorted()
      for (position, percentile) in [15, 30, 31].enumerated() {
        let (scaled, overflow) = rawTicks[percentile].multipliedReportingOverflow(by: numbers[1])
        guard !overflow,
          row[3 + position] == scaled / numbers[2] / UInt64(iterations)
        else { throw ComparisonFailure.observation }
      }
      print(row[0..<8].map(String.init).joined(separator: ","))
    }
  }
}

try inspectComparison()
