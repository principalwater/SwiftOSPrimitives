import PageMemory
import Synchronization
import Testing

private final class DestructionCount {
  var value = 0
}
private struct OwnedToken: ~Copyable {
  let number: Int
  let counter: DestructionCount
  deinit { counter.value += 1 }
}
private func move<Element: ~Copyable>(
  _ value: consuming MappedValue<Element>
) -> MappedValue<Element> { value }

@Suite struct MappedValueTests {
  @Test func ownerMovesKeepTheActualSlotAndDestructor() throws {
    let counter = DestructionCount()
    let initial = try MappedValue.allocate {
      OwnedToken(number: 73, counter: counter)
    }
    let address = try initial.withValue { value in
      #expect(value.count == 1 && value[0].number == 73)
      return value.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
    }
    var moved = move(initial)
    let nextAddress = try moved.withValue { value in
      value.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
    }
    #expect(address != 0 && address == nextAddress)
    #expect(address % UInt(MemoryLayout<OwnedToken>.alignment) == 0)
    #expect(counter.value == 0)
    #expect(throws: PageMemoryError.operationMayBlock) {
      try moved.release(context: .nonblocking)
    }
    #expect(counter.value == 0 && !moved.isDestroyed && !moved.isReleased)
    try moved.release()
    #expect(counter.value == 1 && moved.isDestroyed && moved.isReleased)
    try moved.release()
    #expect(counter.value == 1)
    #expect(throws: PageMemoryError.unavailable) { _ = try moved.withValue { $0.count } }
  }

  @Test func automaticDestructionAndIndependentOwners() throws {
    let counter = DestructionCount()
    var survivor = try MappedValue.allocate { OwnedToken(number: 91, counter: counter) }
    do {
      let temporary = try MappedValue.allocate { OwnedToken(number: 73, counter: counter) }
      #expect(try temporary.withValue { $0[0].number } == 73)
      _ = consume temporary
    }
    #expect(counter.value == 1)
    #expect(try survivor.withValue { $0[0].number } == 91)
    try survivor.release()
    #expect(counter.value == 2)
  }

  @Test func refusalPrecedesFactoryAndInitializationFailurePropagates() throws {
    enum Failure: Error, Equatable { case constructor }
    var factories = 0
    #expect(throws: MappedValueError<Never>.memory(.limitExceeded)) {
      _ = try MappedValue<Int>.allocate(maximumMappedBytes: 1) {
        factories += 1
        return 73
      }
    }
    #expect(throws: MappedValueError<Never>.memory(.operationMayBlock)) {
      _ = try MappedValue<Int>.allocate(context: .nonblocking) {
        factories += 1
        return 73
      }
    }
    #expect(factories == 0)
    #expect(throws: MappedValueError<Failure>.factory(.constructor)) {
      _ = try MappedValue<Int>.allocate { () throws(Failure) -> Int in
        factories += 1
        throw .constructor
      }
    }
    #expect(factories == 1)
    var next = try MappedValue.allocate { 91 }
    #expect(try next.withValue { $0[0] } == 91)
    try next.release()
  }

  @Test func mappingBudgetIncludesPageRounding() throws {
    let sizing = try PageRegion.allocate(byteCount: 1)
    var value = try MappedValue.allocate(maximumMappedBytes: sizing.pageSize) { UInt64(73) }
    #expect(value.mappedByteCount == sizing.pageSize)
    try value.release()
    #expect(throws: PageMemoryError.operationMayBlock) {
      _ = try PageRegion.allocate(byteCount: 1, context: .nonblocking)
    }
  }

  @Test func emptyAlignedAndMultiPageValuesRespectTheirLayouts() throws {
    struct Empty {}
    @_alignment(16) struct Aligned { let value: UInt64 }
    var empty = try MappedValue.allocate { Empty() }
    #expect(try empty.withValue { $0.count } == 1)
    try empty.release()
    var aligned = try MappedValue.allocate { Aligned(value: 73) }
    #expect(
      try aligned.withValue { values in
        values[0].value == 73
          && values.withUnsafeBufferPointer {
            UInt(bitPattern: $0.baseAddress) % 16 == 0
          }
      })
    try aligned.release()
    var large = try MappedValue.allocate { InlineArray<16385, UInt8>(repeating: 91) }
    #expect(large.mappedByteCount > 16384)
    #expect(try large.withValue { $0[0][16384] } == 91)
    try large.release()
    var exact = try MappedValue.allocate { InlineArray<2048, UInt64>(repeating: 73) }
    #expect(exact.mappedByteCount == 16384)
    #expect(try exact.withValue { $0[0][2047] } == 73)
    try exact.release()
  }

  @Test func nativeAtomicAndMutexOperateInTheStableSlot() throws {
    var word = try MappedValue.allocate { Atomic<UInt64>(73) }
    try word.withValue { $0[0].store(91, ordering: .relaxed) }
    #expect(try word.withValue { $0[0].load(ordering: .relaxed) } == 91)
    let individualGeometry = word.mappedByteCount * 1024
    try word.release()
    var compact = try MappedValue.allocate {
      InlineArray<1024, Atomic<UInt64>>(initializingWith: { output in
        for index in 0..<1024 { output.append(Atomic(UInt64(index))) }
      })
    }
    #expect(compact.mappedByteCount < individualGeometry)
    try compact.withValue { $0[0][1023].store(91, ordering: .relaxed) }
    #expect(try compact.withValue { $0[0][1023].load(ordering: .relaxed) } == 91)
    try compact.release()
    var state = try MappedValue.allocate { Mutex<Int>(73) }
    try state.withValue { $0[0].withLock { $0 += 18 } }
    #expect(try state.withValue { $0[0].withLock { $0 } } == 91)
    try state.release()
  }
}
