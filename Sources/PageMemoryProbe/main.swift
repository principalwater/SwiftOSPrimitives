import PageMemory

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#else
  import Musl
#endif

func readKernel(_ path: String, limit: Int = 1_048_576) -> String? {
  let fd = open(path, O_RDONLY | O_CLOEXEC)
  guard fd >= 0 else { return nil }
  defer { _ = close(fd) }
  var bytes = [UInt8](repeating: 0, count: limit)
  var used = 0
  while used < limit {
    let count = bytes.withUnsafeMutableBytes { raw in
      read(fd, raw.baseAddress!.advanced(by: used), limit - used)
    }
    if count == 0 { return String(decoding: bytes[..<used], as: UTF8.self) }
    if count < 0 {
      if errno == EINTR { continue }
      return nil
    }
    used += count
  }
  return nil
}
func memoryField(_ name: String) -> String {
  #if canImport(Darwin)
    return "null"
  #else
    guard let text = readKernel("/proc/self/status", limit: 16384),
      let line = text.split(separator: "\n").first(where: { $0.hasPrefix(name + ":") })
    else { return "null" }
    let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
    guard words.count == 3, words[2] == "kB", let value = UInt64(words[1]),
      value <= UInt64.max / 1024
    else { return "null" }
    return String(value * 1024)
  #endif
}
func processCpuNanoseconds() -> Int64? {
  var value = timespec()
  guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0,
    value.tv_sec >= 0, value.tv_sec <= (Int64.max - 999_999_999) / 1_000_000_000,
    (0..<1_000_000_000).contains(value.tv_nsec)
  else { return nil }
  return Int64(value.tv_sec) * 1_000_000_000 + Int64(value.tv_nsec)
}
func run() throws {
  let args = CommandLine.arguments
  guard args.count >= 2 else { throw PageMemoryError.invalidSize }
  if args[1] == "smaps" {
    #if os(Linux)
      guard let text = readKernel("/proc/self/smaps", limit: 65_536) else {
        throw PageMemoryError.unavailable
      }
      print(text)
      return
    #else
      throw PageMemoryError.unavailable
    #endif
  }
  if args[1] == "baseline" {
    print(
      "{\"schema\":1,\"mode\":\"baseline\",\"rss_bytes\":\(memoryField("VmRSS")),\"hwm_bytes\":\(memoryField("VmHWM"))}"
    )
    return
  }
  guard ["soak", "paced-soak"].contains(args[1]), args.count == 3,
    let cycles = Int(args[2]), (1...10000).contains(cycles)
  else { throw PageMemoryError.invalidSize }
  let before = memoryField("VmRSS")
  let cpuBefore = processCpuNanoseconds()
  var digest = 0
  let started = ContinuousClock.now
  for cycle in 0..<cycles {
    var region = try PageRegion.allocate(byteCount: 1_048_576, maximumMappedBytes: 1_048_576)
    let step = region.pageSize
    try region.withMutableBytes { bytes in
      for offset in stride(from: 0, to: bytes.count, by: step) {
        bytes[offset] = UInt8(cycle % 251 + 1)
      }
    }
    digest &+= try region.withBytes { Int($0[0]) }
    let resident = try region.residentPageCount()
    guard resident > 0 else { throw PageMemoryError.unavailable }
    _ = try region.discardContents()
    #if os(Linux)
      guard try region.residentPageCount() == 0 else { throw PageMemoryError.unavailable }
    #endif
    try region.resetToZero()
    guard try region.withBytes({ $0[0] }) == 0 else { throw PageMemoryError.unavailable }
    try region.release()
    guard region.isReleased else { throw PageMemoryError.unavailable }
    if args[1] == "paced-soak" { _ = usleep(20_000) }
  }
  let duration = started.duration(to: .now).components
  let cpuAfter = processCpuNanoseconds()
  let cpu =
    cpuBefore.flatMap { before in
      cpuAfter.flatMap { after in after >= before ? String(after - before) : nil }
    } ?? "null"
  let nanoseconds = duration.seconds * 1_000_000_000 + duration.attoseconds / 1_000_000_000
  print(
    "{\"schema\":1,\"mode\":\"soak\",\"cycles\":\(cycles),\"digest\":\(digest),\"wall_ns\":\(nanoseconds),\"cpu_ns\":\(cpu),\"rss_before_bytes\":\(before),\"rss_after_bytes\":\(memoryField("VmRSS")),\"hwm_bytes\":\(memoryField("VmHWM")),\"mapped_budget_bytes\":1048576}"
  )
}
do { try run() } catch {
  print("page-memory-probe failed: \(error)")
  exit(2)
}
