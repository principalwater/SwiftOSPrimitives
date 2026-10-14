import _Volatile

#if os(Linux) && hasFeature(Embedded)
  import FramePOSIX
#elseif canImport(Darwin)
  import Darwin
#elseif canImport(Musl)
  import Musl
#elseif os(Windows)
  import WinSDK
  import ucrt
#else
  import Glibc
#endif

@inline(__always)
func currentTicks() -> UInt64 {
  #if canImport(Darwin)
    return mach_absolute_time()
  #elseif os(Windows)
    var ticks = LARGE_INTEGER()
    precondition(unsafe QueryPerformanceCounter(&ticks) && ticks.QuadPart >= 0)
    return unsafe UInt64(ticks.QuadPart)
  #else
    var time = timespec(tv_sec: 0, tv_nsec: 0)
    precondition(unsafe clock_gettime(CLOCK_MONOTONIC_RAW, &time) == 0)
    precondition(time.tv_sec >= 0 && time.tv_nsec >= 0 && time.tv_nsec < 1_000_000_000)
    return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
  #endif
}
@inline(never)
@unsafe func churnStep(
  _ ledger: inout FrameLedger, iteration: Int, request: UnsafePointer<UInt64>
) -> UInt64 {
  let input = unsafe VolatileMappedRegister<UInt64>(unsafeBitPattern: UInt(bitPattern: request))
    .load()
  precondition(input == 1)
  let firstCount = 1 + (iteration + Int(input)) % 7
  let secondCount = 1 + (iteration + Int(input)) % 3
  guard case .reserved(let first) = ledger.reserve(frameCount: firstCount, alignment: 8),
    case .reserved(let second) = ledger.reserve(frameCount: secondCount, alignment: 2)
  else { preconditionFailure("Churn reservation refused") }
  let firstFrame = first.firstFrame
  let secondFrame = second.firstFrame
  precondition(firstFrame == 8 && secondFrame == 4)
  precondition(ledger.availableCount == ledger.capacity - firstCount - secondCount)
  guard case .released = ledger.release(consume second),
    case .reserved(let replacement) = ledger.reserve(frameCount: secondCount, alignment: 2)
  else { preconditionFailure("Churn reuse failed") }
  precondition(replacement.firstFrame == secondFrame)
  guard case .released = ledger.release(consume first),
    case .released = ledger.release(consume replacement)
  else { preconditionFailure("Churn release refused") }
  precondition(ledger.availableCount == ledger.capacity)
  return UInt64(firstFrame + secondFrame) + UInt64(iteration)
}
@inline(never)
@unsafe func refusalStep(
  _ ledger: inout FrameLedger, iteration: Int, request: UnsafePointer<UInt64>, expectedFree: Int
) -> UInt64 {
  let input = unsafe VolatileMappedRegister<UInt64>(unsafeBitPattern: UInt(bitPattern: request))
    .load()
  guard input <= UInt(Int.max),
    case .refused(.capacityExceeded) = ledger.reserve(frameCount: Int(input))
  else { preconditionFailure("Occupied or fragmented range admitted") }
  let free = ledger.availableCount
  precondition(free == expectedFree)
  return UInt64(free) + UInt64(iteration)
}
func emit(_ value: UInt64) {
  var digits: InlineArray<20, UInt8> = .init(repeating: 0)
  var number = value
  var count = 0
  repeat {
    digits[count] = UInt8(number % 10) + 48
    number /= 10
    count += 1
  } while number != 0
  for index in (0..<count).reversed() { _ = putchar(Int32(digits[index])) }
  _ = putchar(10)
}
@unsafe func measure(
  _ ledger: inout FrameLedger, ticks: inout InlineArray<32, UInt64>,
  iterations: Int, mode: Int, request: UnsafePointer<UInt64>, expectedFree: Int
) -> UInt64 {
  var checksum: UInt64 = 0
  for batch in 0..<34 {
    let begin = currentTicks()
    var digest: UInt64 = 0
    for iteration in 0..<iterations {
      digest +=
        unsafe mode == 0
        ? churnStep(&ledger, iteration: iteration, request: request)
        : refusalStep(&ledger, iteration: iteration, request: request, expectedFree: expectedFree)
    }
    let elapsed = currentTicks() - begin
    let expected =
      UInt64(iterations * (iterations - 1) / 2)
      + UInt64(iterations * (mode == 0 ? 12 : expectedFree))
    precondition(digest == expected)
    if batch >= 2 {
      ticks[batch - 2] = elapsed
      checksum += digest
    }
  }
  return checksum
}
@main struct FrameComparison {
  static func main() {
    var metadata: InlineArray<65537, UInt64> = .init(repeating: 0)
    let capacities: InlineArray<5, Int> = [128, 1024, 4096, 16384, 65536]
    #if canImport(Darwin)
      var info = mach_timebase_info_data_t(numer: 0, denom: 0)
      precondition(unsafe mach_timebase_info(&info) == KERN_SUCCESS && info.denom != 0)
      let numerator = UInt64(info.numer)
      let denominator = UInt64(info.denom)
    #elseif os(Windows)
      var frequency = LARGE_INTEGER()
      precondition(unsafe QueryPerformanceFrequency(&frequency) && frequency.QuadPart > 0)
      let numerator: UInt64 = 1_000_000_000
      let denominator = unsafe UInt64(frequency.QuadPart)
    #else
      let numerator: UInt64 = 1
      let denominator: UInt64 = 1
    #endif
    var clockPairs: InlineArray<32, UInt64> = .init(repeating: 0)
    for index in 0..<32 {
      let begin = currentTicks()
      clockPairs[index] = currentTicks() - begin
    }
    emit(2)
    emit(numerator)
    emit(denominator)
    emit(UInt64(MemoryLayout<InlineArray<65537, UInt64>>.size))
    emit(metadata.span.withUnsafeBufferPointer { UInt64(UInt(bitPattern: $0.baseAddress) & 63) })
    for index in 0..<32 { emit(clockPairs[index]) }
    for capacityIndex in 0..<5 {
      let capacity = capacities[capacityIndex]
      for mode in 0..<3 {
        metadata[0] = 0
        var ticks: InlineArray<32, UInt64> = .init(repeating: 0)
        let iterations = mode == 0 ? 256 : mode == 1 ? 32 : 16
        var request = UInt64(mode == 2 ? capacity / 2 : 1)
        var checksum: UInt64 = 0
        withUnsafePointer(to: &request) { pointer in
          var all = metadata.mutableSpan
          let loan = all._mutatingExtracting(0..<(capacity + 1))
          guard var ledger = FrameLedger(metadata: consume loan, firstFrame: 3) else {
            preconditionFailure("Fresh metadata refused")
          }
          if mode == 0 {
            checksum = unsafe measure(
              &ledger, ticks: &ticks, iterations: iterations, mode: mode,
              request: pointer, expectedFree: capacity)
          } else if mode == 1 {
            guard case .reserved(let full) = ledger.reserve(frameCount: capacity) else {
              preconditionFailure("Full setup refused")
            }
            checksum = unsafe measure(
              &ledger, ticks: &ticks, iterations: iterations, mode: mode,
              request: pointer, expectedFree: 0)
            guard case .released = ledger.release(consume full) else {
              preconditionFailure("Full release failed")
            }
          } else {
            let quarter = capacity / 4
            guard case .reserved(let first) = ledger.reserve(frameCount: quarter),
              case .reserved(let second) = ledger.reserve(frameCount: quarter),
              case .reserved(let third) = ledger.reserve(frameCount: quarter),
              case .reserved(let fourth) = ledger.reserve(frameCount: quarter),
              case .released = ledger.release(consume first),
              case .released = ledger.release(consume third)
            else { preconditionFailure("Fragment setup failed") }
            checksum = unsafe measure(
              &ledger, ticks: &ticks, iterations: iterations, mode: mode,
              request: pointer, expectedFree: capacity / 2)
            guard case .released = ledger.release(consume second),
              case .released = ledger.release(consume fourth)
            else { preconditionFailure("Fragment release failed") }
          }
          precondition(ledger.availableCount == capacity)
        }
        let generation = UInt64(mode == 0 ? 34 * iterations * 3 : mode == 1 ? 1 : 4)
        precondition(metadata[0] == generation)
        for index in 1..<65537 { precondition(metadata[index] == 0) }
        let rawTicks = ticks
        for index in 1..<32 {
          var current = index
          while current > 0 && ticks[current] < ticks[current - 1] {
            let temporary = ticks[current]
            ticks[current] = ticks[current - 1]
            ticks[current - 1] = temporary
            current -= 1
          }
        }
        emit(UInt64(capacity))
        emit(UInt64(mode))
        emit(UInt64(iterations))
        let percentiles: InlineArray<3, Int> = [15, 30, 31]
        for position in 0..<3 {
          let index = percentiles[position]
          emit(ticks[index] * numerator / denominator / UInt64(iterations))
        }
        emit(checksum)
        emit(generation)
        for index in 0..<32 { emit(rawTicks[index]) }
      }
    }
  }
}
