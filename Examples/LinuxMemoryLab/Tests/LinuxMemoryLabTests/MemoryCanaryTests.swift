import MemoryCanary
import Testing

@Test func canaryMatchesScalarPatternAcrossOffsetsAndTails() throws {
  for multiplier: UInt8 in [17, 31] {
    let seed: UInt8 = multiplier == 17 ? 91 : 47
    for offset in 0..<16 {
      for count in [0, 1, 7, 8, 9, 255, 256, 257, 1025] {
        var storage = [UInt8](repeating: 0xA5, count: count + 32)
        do {
          var span = storage.mutableSpan
          var bytes = span._mutatingExtracting(offset..<(offset + count))
          MemoryCanary.fill(&bytes, multiplier: multiplier, seed: seed)
          try MemoryCanary.check(bytes.span, multiplier: multiplier, seed: seed)
        }
        for index in storage.indices {
          let expected: UInt8 = (offset..<(offset + count)).contains(index)
            ? UInt8(truncatingIfNeeded: index - offset) &* multiplier &+ seed : 0xA5
          #expect(storage[index] == expected)
        }
      }
    }
  }
}

@Test func canaryDetectsCorruptionAtWordTileAndTailBoundaries() throws {
  for offset in [0, 7, 8, 255, 256, 1024] {
    var storage = [UInt8](repeating: 0, count: 1025)
    var bytes = storage.mutableSpan
    MemoryCanary.fill(&bytes, multiplier: 31, seed: 47)
    bytes[offset] ^= 1
    #expect(throws: MemoryCanary.Failure.mismatch) {
      try MemoryCanary.check(bytes.span, multiplier: 31, seed: 47)
    }
  }
}
