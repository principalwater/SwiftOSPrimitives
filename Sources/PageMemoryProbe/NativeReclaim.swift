#if os(macOS)
  import Darwin
  import PageMemory

  private struct NativePageObservation {
    let mincoreBefore: Int
    let mincoreAfter: Int
    let flags: DarwinPageDispositionCounts
    let queryNanoseconds: UInt64
    let process: ProcessMemorySnapshot

    var json: String {
      "{\"mincore_before\":\(mincoreBefore),\"mincore_after\":\(mincoreAfter),"
        + "\"pages\":\(flags.pageCount),\"present\":\(flags.presentPages),"
        + "\"paged_out\":\(flags.pagedOutPages),\"reusable\":\(flags.reusablePages),"
        + "\"query_ns\":\(queryNanoseconds),\"rss\":\(process.residentBytes),"
        + "\"footprint\":\(process.physicalFootprintBytes.map(String.init) ?? "null")}"
    }
  }
  private struct NativeReclaimCycle {
    let touched: NativePageObservation
    let afterErase: NativePageObservation
    let afterDiscard: NativePageObservation
    let eraseNanoseconds: UInt64
    let discardNanoseconds: UInt64
    let request: Reclamation?
  }

  /// A finite self-owned probe; no other process, VM or system pressure is controlled.
  func nativeReclaimProbe(_ args: [String]) throws {
    guard args.count == 5,
      ["held", "erased", "anonymous", "reusable", "reclaimable"].contains(args[2]),
      let cycles = Int(args[3]), (1...16).contains(cycles),
      let size = Int(args[4]), (1...16_777_216).contains(size)
    else { throw PageMemoryError.invalidSize }
    let mode = args[2]
    var canary = try PageRegion.allocate(byteCount: 8 * 1_048_576)
    try canary.withMutableBytes { bytes in
      for index in 0..<bytes.count { bytes[index] = UInt8(truncatingIfNeeded: index &* 73 &+ 19) }
    }
    func checkCanary() throws {
      guard
        try canary.withBytes({ bytes in
          for index in 0..<bytes.count {
            if bytes[index] != UInt8(truncatingIfNeeded: index &* 73 &+ 19) { return false }
          }
          return true
        })
      else { throw PageMemoryError.unavailable }
    }
    var region = try PageRegion.allocate(
      byteCount: size, backing: mode == "reclaimable" ? .reclaimable : .anonymous)
    func observe(_ owner: borrowing PageRegion) throws -> NativePageObservation {
      let before = try owner.residentPageCount()
      let start = try monotonicNanoseconds()
      let flags = try owner.darwinPageDispositionCounts()
      let query = try monotonicNanoseconds() - start
      return NativePageObservation(
        mincoreBefore: before, mincoreAfter: try owner.residentPageCount(), flags: flags,
        queryNanoseconds: query, process: try ProcessMemorySnapshot.capture())
    }
    let baseline = try observe(region)
    // Initialize the complete bounded result storage before measurement, then serialize after release.
    var records = [NativeReclaimCycle](
      repeating: NativeReclaimCycle(
        touched: baseline, afterErase: baseline, afterDiscard: baseline,
        eraseNanoseconds: 0, discardNanoseconds: 0, request: nil), count: cycles)
    _ = try observe(region)
    let cpuStart = processCpuNanoseconds()
    let started = try monotonicNanoseconds()
    let pageSize = region.pageSize
    let mappedBytes = region.mappedByteCount
    for cycle in 0..<cycles {
      try checkCanary()
      try region.withMutableBytes { bytes in
        for index in 0..<bytes.count { bytes[index] = UInt8(truncatingIfNeeded: index &* 31 &+ 7) }
      }
      let touched = try observe(region)
      let eraseStart = try monotonicNanoseconds()
      if mode != "held" {
        try region.eraseContents()
        guard
          try region.withBytes({ bytes in
            for index in 0..<bytes.count { if bytes[index] != 0 { return false } }
            return true
          })
        else { throw PageMemoryError.unavailable }
      }
      let erase = try monotonicNanoseconds() - eraseStart
      let afterErase = try observe(region)
      let discardStart = try monotonicNanoseconds()
      let request: Reclamation?
      if mode != "held" && mode != "erased" {
        request = try region.discardContents(
          using: mode == "reusable" ? .reusable : .platformDefault)
      } else {
        request = nil
      }
      let discard = try monotonicNanoseconds() - discardStart
      let afterDiscard = try observe(region)
      if request != nil {
        do {
          _ = try region.withBytes { $0[0] }
          throw PageMemoryError.unavailable
        } catch PageMemoryError.contentsDiscarded {}
        try region.resetToZero()
      }
      guard
        try region.withBytes({ bytes in
          for index in 0..<bytes.count {
            let expected: UInt8 = mode == "held" ? UInt8(truncatingIfNeeded: index &* 31 &+ 7) : 0
            if bytes[index] != expected { return false }
          }
          return true
        })
      else { throw PageMemoryError.unavailable }
      try checkCanary()
      records[cycle] = NativeReclaimCycle(
        touched: touched, afterErase: afterErase, afterDiscard: afterDiscard,
        eraseNanoseconds: erase, discardNanoseconds: discard, request: request)
    }
    try region.eraseContents()
    try region.release()
    try checkCanary()
    try canary.eraseContents()
    try canary.release()
    let cpuEnd = processCpuNanoseconds()
    let cpu = cpuStart.flatMap { first in cpuEnd.map { String($0 - first) } } ?? "null"
    let wall = try monotonicNanoseconds() - started
    for (cycle, record) in records.enumerated() {
      let request: String
      if let report = record.request {
        request =
          "{\"advised_bytes\":\(report.advisedBytes),\"semantics\":\"\(report.semantics.rawValue)\","
          + "\"reusable_advice\":\(report.usesReusableAccounting),"
          + "\"physical_released_bytes\":\(report.physicalReleasedBytes.map(String.init) ?? "null")}"
      } else {
        request = "null"
      }
      print(
        "{\"mode\":\"\(mode)\",\"cycle\":\(cycle),\"page_size\":\(pageSize),"
          + "\"mapped_bytes\":\(mappedBytes),\"erase_verify_ns\":\(record.eraseNanoseconds),"
          + "\"discard_ns\":\(record.discardNanoseconds),\"canary_ok\":true,\"reuse_ok\":true,"
          + "\"request\":\(request),\"touched\":\(record.touched.json),"
          + "\"after_erase\":\(record.afterErase.json),\"after_discard\":\(record.afterDiscard.json)}"
      )
    }
    print(
      "{\"summary\":true,\"mode\":\"\(mode)\",\"cycles\":\(cycles),"
        + "\"cpu_ns\":\(cpu),\"wall_ns\":\(wall),\"released\":true}")
  }
#endif
