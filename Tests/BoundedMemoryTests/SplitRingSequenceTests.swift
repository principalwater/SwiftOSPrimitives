import BoundedMemory
import Testing

@Test func splitRingSequencePreservesFullCountAcrossWireAndSlotWrap() throws {
  var sequence = try #require(SplitRingSequence(queueSize: 8))
  // Independent repeated slot/head counters; the wire wraps while lifetime progress continues.
  var slot: UInt16 = 0
  var head: UInt16 = 0
  var wire: UInt16 = 0
  for completed in 0..<131080 {
    #expect(sequence.completedCount == UInt64(completed))
    #expect(sequence.wireIndex == wire)
    #expect(sequence.ringSlot == slot && sequence.descriptorHead == head)
    let advanced = sequence.advance()
    #expect(advanced)
    wire &+= 1
    slot += 1
    head += 1
    if slot == 8 {
      slot = 0
      head += 1
    }
    if head >= 8 { head -= 8 }
  }
  #expect(sequence.completedCount == 131080 && sequence.wireIndex == 8)
}

@Test func splitRingSequenceRefusesGeometryAndExhaustionWithoutLosingProgress() throws {
  for size: UInt16 in [0, 3, 7, 32769, UInt16.max] {
    #expect(SplitRingSequence(queueSize: size) == nil)
  }
  for size: UInt16 in [1, 2, 8, 32768] {
    var sequence = try #require(SplitRingSequence(queueSize: size, completedCount: UInt64.max - 1))
    #expect(!sequence.isExhausted && sequence.wireIndex == 65534)
    #expect(sequence.ringSlot < size && sequence.descriptorHead < size)
    let advanced = sequence.advance()
    #expect(advanced && sequence.isExhausted && sequence.wireIndex == 65535)
    let exhaustedAdvance = sequence.advance()
    #expect(!exhaustedAdvance && sequence.completedCount == UInt64.max)
    #expect(sequence.ringSlot < size && sequence.descriptorHead < size)
  }
}
