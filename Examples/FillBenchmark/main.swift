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
    var storage: InlineArray<65552, UInt8> = .init(repeating: 71)
    var ticks: InlineArray<1024, UInt64> = .init(repeating: 0)
    var span = storage.mutableSpan
    var info = mach_timebase_info_data_t(numer: 0, denom: 0)
    precondition(unsafe mach_timebase_info(&info) == KERN_SUCCESS && info.denom != 0)
    span.withUnsafeMutableBufferPointer { buffer in
      let base = unsafe buffer.baseAddress.unsafelyUnwrapped
      let destination = unsafe UnsafeMutableRawPointer(base.advanced(by: 1))
      for _ in 0..<8 { _ = unsafe guestMemoryFill(destination, 0x23, 65536) }
      for index in 0..<1024 {
        let begin = mach_absolute_time()
        _ = unsafe guestMemoryFill(destination, Int32(index), 65536)
        ticks[index] = mach_absolute_time() - begin
        precondition(unsafe base[1] == UInt8(truncatingIfNeeded: index))
      }
      precondition(unsafe base[0] == 71 && base[65537] == 71)
    }
    // Fixed-size insertion sort keeps this standalone measurement fixture allocation-free.
    for index in 1..<1024 {
      var current = index
      while current > 0 && ticks[current] < ticks[current - 1] {
        let temporary = ticks[current]
        ticks[current] = ticks[current - 1]
        ticks[current - 1] = temporary
        current -= 1
      }
    }
    emit(ticks[511] * UInt64(info.numer) / UInt64(info.denom))
    emit(ticks[972] * UInt64(info.numer) / UInt64(info.denom))
    emit(ticks[1013] * UInt64(info.numer) / UInt64(info.denom))
  }
}
