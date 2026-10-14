import Synchronization

#if !MEMORY_CONTRACT_STANDALONE
  import BoundedMemory
  import PageMemory
#endif
#if os(Linux) && hasFeature(Embedded)
  import NativePOSIX
#elseif canImport(Darwin)
  import Darwin
#elseif canImport(Musl)
  import Musl
#else
  import Glibc
#endif

private enum ContractFailure: Error { case failed }

private func ticks(_ clock: clockid_t) throws -> UInt64 {
  var value = timespec()
  guard unsafe clock_gettime(clock, &value) == 0, value.tv_sec >= 0,
    value.tv_nsec >= 0 && value.tv_nsec < 1_000_000_000,
    UInt64(value.tv_sec) <= (UInt64.max - 999_999_999) / 1_000_000_000
  else { throw ContractFailure.failed }
  return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

@safe private struct Token: ~Copyable {
  let value: UInt64
  let destroyed: UnsafeMutablePointer<UInt64>
  deinit { unsafe destroyed.pointee += 1 }
}
private func moved(_ value: consuming MappedValue<Token>) -> MappedValue<Token> { value }

private func checkValues() throws -> UInt64 {
  var destroyed: UInt64 = 0
  try withUnsafeMutablePointer(to: &destroyed) { counter in
    for iteration in 0..<256 {
      let owner = try MappedValue.allocate {
        unsafe Token(value: UInt64(iteration), destroyed: counter)
      }
      let address = try owner.withValue {
        $0.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
      }
      var next = moved(owner)
      let valid = try next.withValue {
        $0[0].value == UInt64(iteration)
          && $0.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) } == address
      }
      guard valid else { throw ContractFailure.failed }
      try next.release()
      try next.release()
    }
  }
  guard destroyed == 256 else { throw ContractFailure.failed }
  var called = false
  do {
    _ = try MappedValue<Int>.allocate(context: .nonblocking) {
      called = true
      return 1
    }
    throw ContractFailure.failed
  } catch MappedValueError<Never>.memory(.operationMayBlock) {}
  guard !called else { throw ContractFailure.failed }
  return destroyed
}

// Real page backing with scoped typed metadata; the existing ledger supplies all allocation logic.
private func checkFrames(_ region: inout PageRegion) throws -> UInt64 {
  try region.withWriteAccess { bytes throws(ContractFailure) -> UInt64 in
    var arena = ScratchArena(storage: bytes._mutatingExtracting(0..<bytes.count))
    let result = try arena.withTypedAllocation(of: UInt64.self, capacity: 1025) {
      output, remainder throws(ContractFailure) -> UInt64 in
      for _ in 0..<1025 { output.append(0) }
      guard var ledger = FrameLedger(metadata: output.mutableSpan) else {
        throw .failed
      }
      var digest: UInt64 = 0
      let payload = try remainder.withAllocation(byteCount: 1024 * 64, alignment: 64) {
        data, _ throws(ContractFailure) -> UInt64 in
        for iteration in 0..<4096 {
          guard case .reserved(let ticket) = ledger.reserve(frameCount: 3, alignment: 4) else {
            throw .failed
          }
          let offset = Int(ticket.firstFrame) * 64
          data[offset] = UInt8(iteration % 251 + 1)
          digest += UInt64(data[offset])
          guard ledger.availableCount == 1021,
            case .released = ledger.release(ticket), ledger.availableCount == 1024
          else { throw .failed }
        }
        guard case .reserved(let full) = ledger.reserve(frameCount: 1024) else {
          throw .failed
        }
        guard case .refused(.capacityExceeded) = ledger.reserve(frameCount: 1),
          case .released = ledger.release(full), ledger.availableCount == 1024
        else { throw .failed }
        return digest
      }
      guard case .allocated(let observed) = payload else { throw .failed }
      return observed
    }
    guard case .allocated(let observed) = result else { throw .failed }
    return observed
  }
}

private func run() throws {
  let cpuBefore = try ticks(CLOCK_PROCESS_CPUTIME_ID)
  let started = try ticks(CLOCK_MONOTONIC)
  let initial = try ProcessMemorySnapshot.capture()
  let destroyed = try checkValues()
  var compact = try MappedValue.allocate {
    InlineArray<1024, Atomic<UInt64>>(initializingWith: { output in
      for index in 0..<1024 { output.append(Atomic(UInt64(index))) }
    })
  }
  try compact.withValue { cells in
    for index in 0..<1024 { cells[0][index].store(UInt64(index + 1), ordering: .relaxed) }
  }
  guard try compact.withValue({ $0[0][1023].load(ordering: .relaxed) == 1024 }) else {
    throw ContractFailure.failed
  }
  let compactBytes = compact.mappedByteCount
  try compact.release()
  var region = try PageRegion.allocate(byteCount: 2 * 1_048_576)
  let digest = try checkFrames(&region)
  guard digest == 509_256 else { throw ContractFailure.failed }
  let step = region.pageSize
  try region.withMutableBytes { bytes in
    for index in stride(from: 0, to: bytes.count, by: step) { bytes[index] = 73 }
  }
  let touched = try region.residentPageCount()
  let report = try region.discardContents(using: .reusable)
  let discarded = try region.residentPageCount()
  #if os(Linux)
    guard discarded == 0 else { throw ContractFailure.failed }
  #endif
  try region.resetToZero()
  guard try region.withBytes({ $0[0] == 0 && $0[$0.count - 1] == 0 }) else {
    throw ContractFailure.failed
  }
  try region.release()
  let final = try ProcessMemorySnapshot.capture()
  let cpu = try ticks(CLOCK_PROCESS_CPUTIME_ID) - cpuBefore
  let wall = try ticks(CLOCK_MONOTONIC) - started
  print(
    "{\"pass\":true,\"destructions\":\(destroyed),\"compact_slots\":1024,"
      + "\"compact_mapped_bytes\":\(compactBytes),\"digest\":\(digest),"
      + "\"touched_pages\":\(touched),\"discarded_pages\":\(discarded),"
      + "\"advised_bytes\":\(report.advisedBytes),\"wall_ns\":\(wall),\"cpu_ns\":\(cpu),"
      + "\"before_rss\":\(initial.residentBytes),\"after_rss\":\(final.residentBytes)}")
}

do { try run() } catch {
  print("Memory contract probe failed: \(error)")
  exit(1)
}
