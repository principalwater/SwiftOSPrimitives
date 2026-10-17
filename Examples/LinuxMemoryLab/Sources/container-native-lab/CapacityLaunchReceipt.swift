/// One newline-terminated guest receipt, before replacing itself with the application via execv.
struct CapacityLaunchReceipt {
  let totalBytes: UInt64
  let elapsedNanoseconds: UInt64

  init?(line: Substring, minimum: UInt64, maximum: UInt64) {
    guard line.utf8.count <= 128, line.last == "\n", minimum > 0, minimum <= maximum else {
      return nil
    }
    let fields = line.dropLast().split(separator: " ", omittingEmptySubsequences: false)
    guard fields.count == 3, fields[0] == "CAPACITY_READY",
      fields.dropFirst().allSatisfy({
        !$0.isEmpty && ($0 == "0" || $0.first != "0")
          && $0.utf8.allSatisfy { (48...57).contains($0) }
      }),
      let total = UInt64(fields[1]), (minimum...maximum).contains(total),
      let elapsed = UInt64(fields[2]), elapsed < 8_000_000_000
    else { return nil }
    totalBytes = total
    elapsedNanoseconds = elapsed
  }
}
