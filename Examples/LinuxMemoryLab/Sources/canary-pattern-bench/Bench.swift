import MemoryCanary
import PageMemory

@main struct Bench {
  static func main() throws {
    var region = try PageRegion.allocate(byteCount: 64 << 20)
    try region.withMutableBytes { MemoryCanary.fill(&$0, multiplier: 31, seed: 47) }
    for batched in [false, true, true, false] {
      let start = ContinuousClock.now
      for _ in 0..<2 {
        try region.withMutableBytes { bytes in
          if batched { MemoryCanary.fill(&bytes, multiplier: 31, seed: 47) }
          else {
            for index in bytes.indices {
              bytes[index] = UInt8(truncatingIfNeeded: index &* 31 &+ 47)
            }
          }
        }
        try region.withReadAccess { bytes in
          if batched { try MemoryCanary.check(bytes, multiplier: 31, seed: 47) }
          else {
            for index in bytes.indices {
              guard bytes[index] == UInt8(truncatingIfNeeded: index &* 31 &+ 47) else {
                throw MemoryCanary.Failure.mismatch
              }
            }
          }
        }
      }
      print("batched=\(batched) bytes=67108864 rounds=2 elapsed=\(start.duration(to: .now))")
    }
    try region.release()
  }
}
