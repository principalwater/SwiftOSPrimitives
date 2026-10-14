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
func monotonicNanoseconds() throws -> UInt64 {
  var value = timespec()
  #if canImport(Darwin)
    let clock = CLOCK_MONOTONIC_RAW
  #else
    let clock = CLOCK_MONOTONIC
  #endif
  guard clock_gettime(clock, &value) == 0, value.tv_sec >= 0,
    (0..<1_000_000_000).contains(value.tv_nsec),
    UInt64(value.tv_sec) <= (UInt64.max - 999_999_999) / 1_000_000_000
  else { throw PageMemoryError.unavailable }
  return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}
@inline(never) func observedDigest(_ bytes: Span<UInt8>, step: Int) -> UInt64 {
  var result: UInt64 = 0
  for offset in stride(from: 0, to: bytes.count, by: step) { result += UInt64(bytes[offset]) }
  return result + UInt64(bytes[bytes.count - 1])
}
func transact(_ region: inout PageRegion, cycle: Int) throws -> UInt64 {
  let empty = try region.withBytes { $0[0] == 0 && $0[$0.count - 1] == 0 }
  guard empty else { throw PageMemoryError.contentsDiscarded }
  let step = region.pageSize
  try region.withMutableBytes { bytes in
    let value = UInt8(cycle % 251 + 1)
    for offset in stride(from: 0, to: bytes.count, by: step) { bytes[offset] = value }
    bytes[bytes.count - 1] = value
  }
  return try region.withBytes { observedDigest($0, step: step) }
}
func cycleBenchmark(_ args: [String]) throws {
  guard args.count == 5, ["allocate", "reuse", "reusable"].contains(args[2]),
    let cycles = Int(args[3]), (1...10000).contains(cycles),
    let size = Int(args[4]), (1...16_777_216).contains(size)
  else { throw PageMemoryError.invalidSize }
  let allocates = args[2] == "allocate"
  let reusable = args[2] == "reusable"
  var samples = [UInt64](repeating: UInt64.max, count: cycles)
  var persistent: PageRegion? = allocates ? nil : try PageRegion.allocate(byteCount: size)
  _ = try ProcessMemorySnapshot.capture()
  let before = try ProcessMemorySnapshot.capture()
  let cpuBefore = processCpuNanoseconds()
  let started = try monotonicNanoseconds()
  var digest: UInt64 = 0
  for cycle in 0..<cycles {
    let tick = try monotonicNanoseconds()
    if allocates {
      var region = try PageRegion.allocate(byteCount: size)
      digest += try transact(&region, cycle: cycle)
      try region.release()
    } else {
      guard persistent != nil else { throw PageMemoryError.unavailable }
      digest += try transact(&persistent!, cycle: cycle)
      if reusable { _ = try persistent!.discardContents(using: .reusable) }
      try persistent!.resetToZero()
    }
    samples[cycle] = try monotonicNanoseconds() - tick
  }
  let elapsed = try monotonicNanoseconds() - started
  let cpuAfter = processCpuNanoseconds()
  let after = try ProcessMemorySnapshot.capture()
  try persistent?.release()
  samples.sort()
  let cpu =
    cpuBefore.flatMap { before in
      cpuAfter.flatMap { after in after >= before ? String(after - before) : nil }
    } ?? "null"
  func percentile(_ percent: Int) -> UInt64 { samples[min(cycles - 1, cycles * percent / 100)] }
  print(
    "{\"mode\":\"\(args[2])\",\"cycles\":\(cycles),\"byte_count\":\(size),\"digest\":\(digest),\"wall_ns\":\(elapsed),\"cpu_ns\":\(cpu),\"p50_ns\":\(percentile(50)),\"p95_ns\":\(percentile(95)),\"p99_ns\":\(percentile(99)),\"before_rss_bytes\":\(before.residentBytes),\"after_rss_bytes\":\(after.residentBytes),\"before_footprint_bytes\":\(before.physicalFootprintBytes.map(String.init) ?? "null"),\"after_footprint_bytes\":\(after.physicalFootprintBytes.map(String.init) ?? "null")}"
  )
}
func reclaimProbe(_ args: [String]) throws {
  guard args.count == 5, ["held", "anonymous", "reusable", "reclaimable"].contains(args[2]),
    let cycles = Int(args[3]), (1...100).contains(cycles),
    let size = Int(args[4]), (1...16_777_216).contains(size)
  else { throw PageMemoryError.invalidSize }
  let held = args[2] == "held"
  var region = try PageRegion.allocate(
    byteCount: size, backing: args[2] == "reclaimable" ? .reclaimable : .anonymous)
  _ = try ProcessMemorySnapshot.capture()
  let baseline = try ProcessMemorySnapshot.capture()
  let started = try monotonicNanoseconds()
  let cpuStart = processCpuNanoseconds()
  func fields(_ value: ProcessMemorySnapshot) -> String {
    "{\"rss\":\(value.residentBytes),\"footprint\":\(value.physicalFootprintBytes.map(String.init) ?? "null")}"
  }
  for cycle in 0..<cycles {
    try region.withMutableBytes { bytes in
      for index in 0..<bytes.count { bytes[index] = 73 }
    }
    let touchedPages = try region.residentPageCount()
    let touched = try ProcessMemorySnapshot.capture()
    let eraseStart = try monotonicNanoseconds()
    try region.eraseContents()
    let eraseNanoseconds = try monotonicNanoseconds() - eraseStart
    let zeroed = try region.withBytes { bytes in
      for index in 0..<bytes.count { if bytes[index] != 0 { return false } }
      return true
    }
    guard zeroed else { throw PageMemoryError.unavailable }
    let discardStart = try monotonicNanoseconds()
    let report =
      held
      ? nil
      : try region.discardContents(
        using: args[2] == "reusable" ? .reusable : .platformDefault)
    let discardNanoseconds = try monotonicNanoseconds() - discardStart
    let discardedPages = try region.residentPageCount()
    let discarded = try ProcessMemorySnapshot.capture()
    if !held {
      do {
        _ = try region.withBytes { $0[0] }
        throw PageMemoryError.unavailable
      } catch PageMemoryError.contentsDiscarded {}
      try region.resetToZero()
    }
    let resetZero = try region.withBytes { bytes in
      for index in 0..<bytes.count { if bytes[index] != 0 { return false } }
      return true
    }
    guard resetZero else { throw PageMemoryError.unavailable }
    print(
      "{\"mode\":\"reclaim\",\"strategy\":\"\(args[2])\",\"cycle\":\(cycle),\"page_size\":\(region.pageSize),\"mapped_bytes\":\(region.mappedByteCount),\"touched_pages\":\(touchedPages),\"discarded_pages\":\(discardedPages),\"erase_ns\":\(eraseNanoseconds),\"discard_ns\":\(discardNanoseconds),\"erase_verified\":true,\"reset_verified\":true,\"semantics\":\"\(report?.semantics.rawValue ?? "held")\",\"physical_released_bytes\":null,\"baseline\":\(fields(baseline)),\"touched\":\(fields(touched)),\"discarded\":\(fields(discarded))}"
    )
  }
  try region.eraseContents()
  try region.release()
  let released = try ProcessMemorySnapshot.capture()
  let cpuEnd = processCpuNanoseconds()
  let cpu = cpuStart.flatMap { begin in cpuEnd.map { String($0 - begin) } } ?? "null"
  print(
    "{\"mode\":\"reclaim_summary\",\"strategy\":\"\(args[2])\",\"cycles\":\(cycles),\"wall_ns\":\(try monotonicNanoseconds() - started),\"cpu_ns\":\(cpu),\"released\":\(fields(released))}"
  )
}

func run() throws {
  let args = CommandLine.arguments
  guard args.count >= 2 else { throw PageMemoryError.invalidSize }
  if args[1] == "reclaim" {
    try reclaimProbe(args)
    return
  }
  if args[1] == "cycle" {
    try cycleBenchmark(args)
    return
  }
  if args[1] == "footprint" {
    guard args.count == 3, ["default", "reusable"].contains(args[2]) else {
      throw PageMemoryError.invalidSize
    }
    _ = try ProcessMemorySnapshot.capture()
    let before = try ProcessMemorySnapshot.capture()
    var region = try PageRegion.allocate(byteCount: 16 * 1_048_576)
    let step = region.pageSize
    try region.withMutableBytes { bytes in
      for offset in stride(from: 0, to: bytes.count, by: step) { bytes[offset] = 73 }
    }
    let touched = try ProcessMemorySnapshot.capture()
    let report = try region.discardContents(
      using: args[2] == "reusable" ? .reusable : .platformDefault)
    let discarded = try ProcessMemorySnapshot.capture()
    try region.resetToZero()
    guard try region.withBytes({ $0[0] }) == 0 else { throw PageMemoryError.unavailable }
    let reset = try ProcessMemorySnapshot.capture()
    try region.release()
    let released = try ProcessMemorySnapshot.capture()
    func fields(_ snapshot: ProcessMemorySnapshot) -> String {
      "{\"rss\":\(snapshot.residentBytes),\"footprint\":\(snapshot.physicalFootprintBytes.map(String.init) ?? "null")}"
    }
    print(
      "{\"mode\":\"footprint\",\"strategy\":\"\(args[2])\",\"semantics\":\"\(report.semantics.rawValue)\",\"uses_reusable_accounting\":\(report.usesReusableAccounting),\"mapped_bytes\":16777216,\"before\":\(fields(before)),\"touched\":\(fields(touched)),\"discarded\":\(fields(discarded)),\"reset\":\(fields(reset)),\"released\":\(fields(released))}"
    )
    return
  }
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
