import Darwin

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

@main struct Benchmark {
  static func main() {
    var metadata: InlineArray<129, UInt64> = .init(repeating: 0)
    var ticks: InlineArray<128, UInt64> = .init(repeating: 0)
    var info = mach_timebase_info_data_t(numer: 0, denom: 0)
    precondition(unsafe mach_timebase_info(&info) == KERN_SUCCESS && info.denom != 0)
    var checksum: UInt64 = 0
    var loan = metadata.mutableSpan
    loan.withUnsafeMutableBufferPointer { buffer in
      for _ in 0..<8 {
        precondition(unsafe frameTrace(buffer.baseAddress, buffer.count, 1000, 3) == 511500)
      }
      for sample in 0..<128 {
        let begin = mach_absolute_time()
        let observed = unsafe frameTrace(buffer.baseAddress, buffer.count, 1000, 3)
        ticks[sample] = mach_absolute_time() - begin
        precondition(observed == 511500)
        checksum += observed
      }
    }
    precondition(metadata[0] == 136 * 3000)
    for index in 1..<129 { precondition(metadata[index] == 0) }
    // Fixed-size sorting and C output keep this Embedded measurement fixture allocation-free.
    for index in 1..<128 {
      var current = index
      while current > 0 && ticks[current] < ticks[current - 1] {
        let temporary = ticks[current]
        ticks[current] = ticks[current - 1]
        ticks[current - 1] = temporary
        current -= 1
      }
    }
    emit(ticks[63] * UInt64(info.numer) / UInt64(info.denom) / 1000)
    emit(ticks[121] * UInt64(info.numer) / UInt64(info.denom) / 1000)
    emit(ticks[126] * UInt64(info.numer) / UInt64(info.denom) / 1000)
    emit(checksum)
  }
}
