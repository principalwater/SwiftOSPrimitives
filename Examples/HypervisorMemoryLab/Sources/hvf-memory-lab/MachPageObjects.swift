import Darwin
import Dispatch
import Foundation
import Hypervisor
import PageMemory

enum MachPageJSON {
  static func hex(_ value: UInt64) -> String { "0x" + String(value, radix: 16) }
  static func orNull(_ value: Any?) -> Any { value ?? NSNull() }
  /// Signed difference; unknown when either side could not be observed. Never clamped to zero.
  static func delta(_ before: UInt64?, _ after: UInt64?) -> Any {
    guard let before, let after else { return NSNull() }
    return Int64(truncatingIfNeeded: after) - Int64(truncatingIfNeeded: before)
  }
}

/// Raw host-wide VM counters, recorded beside process samples as unattributed context. They move
/// for reasons unrelated to this process and never establish a physical release.
struct MachPageHostSample {
  var free: UInt64 = 0
  var active: UInt64 = 0
  var inactive: UInt64 = 0
  var wired: UInt64 = 0
  var speculative: UInt64 = 0
  var compressorPages: UInt64 = 0
  var internalPages: UInt64 = 0
  var externalPages: UInt64 = 0
  var compressions: UInt64 = 0
  var decompressions: UInt64 = 0

  static func capture() -> MachPageHostSample? {
    let host = mach_host_self()
    defer { _ = mach_port_deallocate(mach_task_self_, host) }
    var info = vm_statistics64_data_t()
    let capacity = MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
    var count = mach_msg_type_number_t(capacity)
    let code = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
        host_statistics64(host, HOST_VM_INFO64, $0, &count)
      }
    }
    guard code == KERN_SUCCESS, Int(count) == capacity else { return nil }
    var sample = MachPageHostSample()
    sample.free = UInt64(truncatingIfNeeded: info.free_count)
    sample.active = UInt64(truncatingIfNeeded: info.active_count)
    sample.inactive = UInt64(truncatingIfNeeded: info.inactive_count)
    sample.wired = UInt64(truncatingIfNeeded: info.wire_count)
    sample.speculative = UInt64(truncatingIfNeeded: info.speculative_count)
    sample.compressorPages = UInt64(truncatingIfNeeded: info.compressor_page_count)
    sample.internalPages = UInt64(truncatingIfNeeded: info.internal_page_count)
    sample.externalPages = UInt64(truncatingIfNeeded: info.external_page_count)
    sample.compressions = UInt64(truncatingIfNeeded: info.compressions)
    sample.decompressions = UInt64(truncatingIfNeeded: info.decompressions)
    return sample
  }

  var json: [String: Any] {
    var result: [String: Any] = [:]
    result["unit"] = "kernel VM pages"
    result["attributedToThisProcess"] = false
    result["freePages"] = free
    result["activePages"] = active
    result["inactivePages"] = inactive
    result["wiredPages"] = wired
    result["speculativePages"] = speculative
    result["compressorPages"] = compressorPages
    result["internalPages"] = internalPages
    result["externalPages"] = externalPages
    result["compressionsTotal"] = compressions
    result["decompressionsTotal"] = decompressions
    return result
  }
}

/// A fixed-size sample for the retirement window: it is stored without formatting or allocation.
struct MachPageTimelinePoint {
  var nanos: UInt64
  var resident: UInt64?
  var footprint: UInt64?
  var hostFree: UInt64?
  var json: [String: Any] {
    var result: [String: Any] = [:]
    result["elapsedNanos"] = nanos
    result["residentBytes"] = MachPageJSON.orNull(resident)
    result["physicalFootprintBytes"] = MachPageJSON.orNull(footprint)
    result["hostFreePagesUnattributed"] = MachPageJSON.orNull(hostFree)
    return result
  }
}

enum MachPageExpectation { case canary, zero, fault }

struct MachPageGuestPass {
  var reads = 0
  var matched = 0
  var mismatched = 0
  var exactFaultAddresses = 0
  var elapsedNanos: UInt64 = 0
  var examples: [String] = []
  var json: [String: Any] {
    var result: [String: Any] = [:]
    result["vcpuReads"] = reads
    result["matched"] = matched
    result["mismatched"] = mismatched
    result["faultsWithExactAddress"] = exactFaultAddresses
    result["elapsedNanos"] = elapsedNanos
    result["mismatchExamples"] = examples
    return result
  }
}

enum MachPageSummary {
  static func sample(_ entry: MachPageEntry, base: UInt64) -> [String: Any] {
    var result: [String: Any] = [:]
    result["arenaOffset"] = Int64(truncatingIfNeeded: entry.start) - Int64(truncatingIfNeeded: base)
    result["lengthBytes"] = entry.length
    result["objectOffset"] = entry.offset
    result["objectID"] = MachPageJSON.hex(entry.objectID)
    result["references"] = entry.references
    result["residentPages"] = entry.residentPages
    result["pagedOutPages"] = entry.pagedOutPages
    return result
  }

  /// Aggregates one kernel walk of the arena. Raw first and last entries are kept for audit.
  static func entries(_ entries: [MachPageEntry], base: UInt64) -> [String: Any] {
    let limit = base + UInt64(MachPageGeometry.dataBytes)
    var mapped: UInt64 = 0
    var minimum = UInt64.max
    var maximum: UInt64 = 0
    var once = 0
    var twice = 0
    var otherwise = 0
    var resident: UInt64 = 0
    var pagedOut: UInt64 = 0
    var wired: UInt64 = 0
    var unusual = 0
    var tags: [String: Int] = [:]
    var protections: [String: Int] = [:]
    var shareModes: [String: Int] = [:]
    for entry in entries {
      let low = max(entry.start, base)
      let high = min(entry.end, limit)
      guard high > low else { continue }
      mapped += high - low
      tags[String(entry.tag), default: 0] += 1
      protections["\(entry.protection)/\(entry.maximumProtection)", default: 0] += 1
      shareModes[String(entry.shareMode), default: 0] += 1
      minimum = min(minimum, entry.references)
      maximum = max(maximum, entry.references)
      switch entry.references {
      case 1: once += 1
      case 2: twice += 1
      default: otherwise += 1
      }
      resident += entry.residentPages
      pagedOut += entry.pagedOutPages
      wired += entry.wiredPages + entry.userWired
      if entry.submap || entry.shadowDepth != 0 || entry.externalPager != 0 { unusual += 1 }
    }
    var result: [String: Any] = [:]
    result["entries"] = entries.count
    result["mappedBytes"] = mapped
    // A retired slot is a placeholder, never a hole, so this is zero in every walk.
    result["holeBytes"] = UInt64(MachPageGeometry.dataBytes) - mapped
    result["distinctObjectIdentifiers"] = Set(entries.map(\.objectID).filter { $0 != 0 }).count
    result["entriesWithoutObject"] = entries.filter { $0.objectID == 0 }.count
    // Keys are user tags (240 arena objects, 241 placeholders), "protection/maximum" as raw
    // VM_PROT bits, and the raw share_mode values (SM_* in <mach/vm_region.h>), recorded only.
    result["entriesByTag"] = tags
    result["entriesByProtection"] = protections
    result["entriesByShareMode"] = shareModes
    result["minimumReferences"] = MachPageJSON.orNull(entries.isEmpty ? nil : minimum)
    result["maximumReferences"] = maximum
    result["entriesWithOneReference"] = once
    result["entriesWithTwoReferences"] = twice
    result["entriesWithOtherReferences"] = otherwise
    result["residentPagesReportedByEntries"] = resident
    result["pagedOutPagesReportedByEntries"] = pagedOut
    result["wiredPagesReportedByEntries"] = wired
    result["submapShadowOrPagerEntries"] = unusual
    result["firstEntries"] = entries.prefix(2).map { sample($0, base: base) }
    result["lastEntries"] = entries.suffix(2).map { sample($0, base: base) }
    return result
  }
}

/// One finite run of one profile in this process. Everything happens on the creating thread:
/// VM, vCPU, Mach mappings, HVF mappings and guest runs are sequential, and mappings change
/// only while the vCPU is outside `hv_vcpu_run`. There is no timer, worker or second thread;
/// kernel calls that never return are bounded only by the parent's external watchdog.
final class MachPageExperiment {
  static let timelinePoints = 21
  static let timelineIntervalMicroseconds: useconds_t = 10_000

  let profile: MachPageProfile
  let deadline: DispatchTime
  let machine = Machine()
  private let origin = DispatchTime.now().uptimeNanoseconds
  private var arena: MachPageArena?
  private var guest: MachPageGuest?
  private var currentStage = "not-started"
  private var stageAtEnd = "not-started"
  private var phases: [[String: Any]] = []
  private var entryRecords: [String: Any] = [:]
  private var dispositionRecords: [String: Any] = [:]
  private var memoryRecords: [String: Any] = [:]
  private var guestRecords: [String: Any] = [:]
  private var counters: [String: Any] = [:]
  private var cleanup: [String: Any] = [:]
  private var vmCreateCode: Int?
  private var refused: (operation: String, code: Int32?, detail: String, stage: String)?
  private var primary = ""
  private var deadlineExpired = false
  // Successful atomic placeholder replacements. Ownership is claimed only after every check below.
  private var retiredPages: Int?
  private var ownedRetiredPages: Int?
  private(set) var cleanupErrors: [String] = []
  private(set) var retirement: String?

  init(profile: MachPageProfile, deadline: DispatchTime) {
    self.profile = profile
    self.deadline = deadline
  }

  var outcome: String {
    if let refused {
      let native = refused.code.map { "native code \($0)" } ?? refused.detail
      return "refused: \(refused.operation) (\(native)) at \(refused.stage)"
    }
    return primary.isEmpty ? "completed" : "invalid: \(primary)"
  }

  /// The one refusal a negative mode exists to produce, and where. A negative run that completes,
  /// or stops anywhere else, has not established its control: it is indeterminate, not a pass.
  private var expectedRefusal: (operation: String, stage: String)? {
    switch profile {
    case .single, .pages: return nil
    case .pagesAliased: return ("ownership-proof", "ownership-preflight")
    case .pagesPreFreeAliased: return ("ownership-proof(retire)", "retire")
    }
  }

  /// nil for the positive profiles. For a negative mode: refused as expected, with no backing
  /// retired and no ownership claimed.
  private var negativeControlHeld: Bool? {
    guard let expected = expectedRefusal else { return nil }
    guard primary.isEmpty, let refused else { return false }
    return refused.operation == expected.operation && refused.stage == expected.stage
      && (retiredPages ?? 0) == 0 && ownedRetiredPages == nil
  }

  /// A finding is determinate when the profile either completed or reached a recorded native
  /// refusal (the expected one, for a negative mode), and every cleanup step, the vCPU, the VM
  /// and the arena are verified closed.
  var determinate: Bool {
    primary.isEmpty && !deadlineExpired && retirement == nil && cleanupErrors.isEmpty
      && negativeControlHeld != false && !machine.created && (arena?.released ?? true)
  }

  var summary: String {
    let control = negativeControlHeld == false ? "; negative control did not hold" : ""
    return "\(outcome); cleanup errors \(cleanupErrors.count); deadline expired \(deadlineExpired)"
      + control
  }

  func execute() {
    memoryRecords["start"] = memoryJSON(host: true)
    do {
      try drive()
    } catch let refusal as MachPageRefusal {
      refused = (refusal.operation, refusal.code, refusal.detail, currentStage)
    } catch {
      primary = "\(currentStage): \(error)"
    }
    stageAtEnd = currentStage
    teardown()
    memoryRecords["afterTeardown"] = memoryJSON(host: true)
  }

  private func elapsed() -> UInt64 { DispatchTime.now().uptimeNanoseconds &- origin }

  private func requireTime(_ what: String) throws {
    if DispatchTime.now() >= deadline {
      deadlineExpired = true
      throw Failure.experiment("deadline expired during \(what)")
    }
  }

  /// Records one stage. The single deadline was fixed at start; no stage renews it.
  private func stage(_ name: String, _ body: () throws -> Void) throws {
    try requireTime("start of \(name)")
    currentStage = name
    let started = elapsed()
    var completed = false
    defer {
      phases.append(
        ["name": name, "startNanos": started, "endNanos": elapsed(), "completed": completed])
    }
    try body()
    completed = true
  }

  private func ownedArena() throws -> MachPageArena {
    guard let arena else { throw Failure.state }
    return arena
  }

  private func ownedGuest() throws -> MachPageGuest {
    guard let guest else { throw Failure.state }
    return guest
  }

  private func drive() throws {
    let slots = Array(0..<MachPageGeometry.pageCount)
    let candidates = slots.filter(MachPageGeometry.isCandidate)
    let neighbours = slots.filter { !MachPageGeometry.isCandidate($0) }
    let last = MachPageGeometry.wordsPerPage - 1

    try stage("geometry") {
      guard machine.pageSize == MachPageGeometry.pageSize else { throw Failure.geometry }
    }
    try stage("vm-and-code-page") {
      let code = hv_vm_create(nil)
      vmCreateCode = Int(code)
      try check(code, "vm-create")
      machine.created = true
      try MachPageGuest.install(in: machine)
    }
    try stage("vcpu") {
      var cpu: hv_vcpu_t = 0
      try check(hv_vcpu_create(&cpu, &machine.exitInfo, nil), "vcpu-create")
      machine.cpu = cpu
      try check(hv_vcpu_set_vtimer_mask(cpu, true), "mask-timer")
      guard let record = machine.exitInfo else { throw Failure.state }
      guest = MachPageGuest(machine: machine, cpu: cpu, record: record)
    }
    memoryRecords["beforeArena"] = memoryJSON()

    try stage("arena-install") {
      let started = elapsed()
      let created = try MachPageArena.reserve(profile: profile, machine: machine)
      arena = created
      try created.install(deadline: requireTime)
      var install: [String: Any] = [:]
      install["reservationBytes"] = MachPageGeometry.dataBytes
      install["namedObjectsCreated"] = profile.perPage ? MachPageGeometry.pageCount : 1
      install["objectBytes"] =
        profile.perPage ? MachPageGeometry.pageSize : MachPageGeometry.dataBytes
      install["mapFlags"] = "FIXED|OVERWRITE inside the arena's own tagged reservation"
      install["userTag"] = Int(MachPageGeometry.dataTag)
      install["elapsedNanos"] = elapsed() - started
      counters["install"] = install
    }
    try stage("identity-after-install") {
      let entries = try observeEntries("afterInstall")
      try ownedArena().verifyInstalled(entries)
      try observeDispositions("afterInstallBeforeFirstTouch")
      memoryRecords["afterInstall"] = memoryJSON()
    }
    try stage("first-touch") { try firstTouch() }
    try stage("guest-map") {
      let arena = try ownedArena()
      let started = elapsed()
      try arena.mapGuestWhole()
      var map: [String: Any] = [:]
      map["accepted"] = true
      map["guestPhysicalBase"] = MachPageJSON.hex(MachPageGeometry.dataGPA)
      map["bytes"] = MachPageGeometry.dataBytes
      map["elapsedNanos"] = elapsed() - started
      counters["guestMap"] = map
      _ = try observeEntries("afterGuestMap")
    }
    try stage("guest-baseline") {
      try guestPass("baselineAllPages", slots: slots, word: 0, expecting: .canary)
    }
    try stage("pre-retire-observation") {
      memoryRecords["beforeRetire"] = memoryJSON()
      try observeDispositions("beforeRetire")
      _ = try observeEntries("beforeRetire")
    }
    try stage("guest-unmap-candidates") {
      let arena = try ownedArena()
      let started = elapsed()
      for (index, slot) in candidates.enumerated() {
        if index & 127 == 0 { try requireTime("guest unmap") }
        try arena.unmapGuest(slot: slot)
      }
      var unmap: [String: Any] = [:]
      unmap["pages"] = candidates.count
      unmap["bytes"] = candidates.count * MachPageGeometry.pageSize
      unmap["elapsedNanos"] = elapsed() - started
      counters["guestUnmap"] = unmap
    }
    if profile.perPage {
      try stage("alias-refusal-control") {
        // Harness: only pages-aliased keeps the alias, through the bulk preflight below.
        let control = try ownedArena().aliasControl(slot: 1, keep: profile == .pagesAliased)
        counters["aliasRefusalControl"] = control.json
        guard control.valid else {
          throw Failure.experiment("the ownership proof did not track a deliberate alias")
        }
      }
    }
    try stage("ownership-preflight") {
      let arena = try ownedArena()
      let entries = try observeEntries("afterGuestUnmap")
      let preflight = arena.preflight(candidates, entries: entries)
      var record = preflight.json
      // SINGLE's object is shared by construction: exclusivity is not, and cannot be, enforced.
      record["referenceExclusivityEnforced"] = profile.perPage
      counters["ownershipPreflight"] = record
      // All-or-nothing, like the production BUSY reply: no page is retired after a refusal.
      guard preflight.refused == 0 else {
        throw MachPageRefusal(
          operation: "ownership-proof", code: nil,
          detail: "\(preflight.refused) of \(preflight.examined) candidates: "
            + (preflight.examples.first ?? "no reason recorded"))
      }
    }
    try stage("guest-probe-unmapped") {
      try guestPass("candidatesAfterGuestUnmap", slots: candidates, word: 0, expecting: .fault)
      try guestPass("neighboursAfterGuestUnmap", slots: neighbours, word: 1, expecting: .canary)
    }
    if profile == .pagesPreFreeAliased {
      // Harness: the bulk proof and the guest probes have passed, so this alias is visible only
      // to the point-of-free check inside the first retirement, which must refuse it.
      try stage("alias-before-first-free") {
        let control = try ownedArena().aliasControl(slot: candidates[0], keep: true)
        counters["pointOfFreeAlias"] = control.json
        guard control.valid else {
          throw Failure.experiment("the proof did not see the alias made before the first free")
        }
      }
    }
    try stage("retire") { try retire(candidates) }
    try stage("guest-probe-retired") {
      try guestPass("candidatesAfterRetire", slots: candidates, word: last, expecting: .fault)
      try guestPass("neighboursAfterRetire", slots: neighbours, word: last, expecting: .canary)
    }
    try stage("placeholder-claim-control") {
      let control = try ownedArena().placeholderClaimControl(slot: candidates[0])
      counters["placeholderClaimControl"] = control.json
      guard control.valid else {
        throw Failure.experiment("a non-overwriting claim of an owned placeholder was not refused")
      }
      // Every post-condition of the retirement has now held, so the ownership claim is complete.
      ownedRetiredPages = retiredPages
    }
    try stage("refill") { try refill(candidates) }
    try stage("guest-map-refill") {
      let arena = try ownedArena()
      let started = elapsed()
      for (index, slot) in candidates.enumerated() {
        if index & 127 == 0 { try requireTime("guest map of refilled pages") }
        try arena.mapGuest(slot: slot)
      }
      var map: [String: Any] = [:]
      map["pages"] = candidates.count
      map["elapsedNanos"] = elapsed() - started
      counters["guestMapRefill"] = map
      _ = try observeEntries("afterRefillGuestMap")
    }
    try stage("guest-verify-refill") { try verifyRefill(candidates, neighbours) }
  }

  /// Task counters only unless `host` is set; the host-wide sample is unattributed context.
  private func memoryJSON(host: Bool = false) -> [String: Any] {
    let snapshot = try? ProcessMemorySnapshot.capture()
    var result: [String: Any] = [:]
    result["elapsedNanos"] = elapsed()
    result["residentBytes"] = MachPageJSON.orNull(snapshot?.residentBytes)
    result["physicalFootprintBytes"] = MachPageJSON.orNull(snapshot?.physicalFootprintBytes)
    if host { result["hostCounters"] = MachPageJSON.orNull(MachPageHostSample.capture()?.json) }
    return result
  }

  private func timelinePoint() -> MachPageTimelinePoint {
    let snapshot = try? ProcessMemorySnapshot.capture()
    return MachPageTimelinePoint(
      nanos: elapsed(), resident: snapshot?.residentBytes,
      footprint: snapshot?.physicalFootprintBytes, hostFree: MachPageHostSample.capture()?.free)
  }

  private func observeEntries(_ label: String) throws -> [MachPageEntry] {
    let arena = try ownedArena()
    let entries = try arena.entries()
    entryRecords[label] = MachPageSummary.entries(entries, base: arena.base)
    return entries
  }

  private func observeDispositions(_ label: String) throws {
    dispositionRecords[label] = try ownedArena().dispositions().json
  }

  /// Reads one word of every listed slot through the vCPU. Every mismatch is counted; the stage
  /// fails afterwards, so the evidence shows the full extent (for example a stale translation).
  private func guestPass(
    _ name: String, slots: [Int], word: Int, expecting: MachPageExpectation
  ) throws {
    let arena = try ownedArena()
    let guest = try ownedGuest()
    var pass = MachPageGuestPass()
    let started = elapsed()
    for (index, slot) in slots.enumerated() {
      if index & 127 == 0 { try requireTime("guest pass \(name)") }
      let observation = try guest.read(arena.guestAddress(of: slot) + UInt64(word * 8))
      pass.reads += 1
      var problem: String?
      switch (expecting, observation) {
      case (.canary, .value(let value)):
        if value != MachPageCanary.word(slot: slot, index: word) {
          problem = "slot \(slot) word \(word) read \(MachPageJSON.hex(value))"
        }
      case (.zero, .value(let value)):
        if value != 0 { problem = "slot \(slot) word \(word) read \(MachPageJSON.hex(value))" }
      case (.fault, .translationFault(let exact)):
        if exact { pass.exactFaultAddresses += 1 }
      default:
        problem = "slot \(slot) word \(word) expected \(expecting) observed \(observation)"
      }
      if let problem {
        pass.mismatched += 1
        if pass.examples.count < 4 { pass.examples.append(problem) }
      } else {
        pass.matched += 1
      }
    }
    pass.elapsedNanos = elapsed() - started
    guestRecords[name] = pass.json
    guard pass.mismatched == 0 else {
      throw Failure.experiment("guest pass \(name): \(pass.mismatched) of \(pass.reads) reads")
    }
  }

  private func firstTouch() throws {
    let arena = try ownedArena()
    let started = elapsed()
    try arena.fill(deadline: requireTime)
    let filled = elapsed()
    var mismatches = 0
    for slot in 0..<MachPageGeometry.pageCount {
      if slot & 127 == 0 { try requireTime("host readback") }
      mismatches += try arena.hostMismatches(slot: slot, zero: false)
    }
    var touch: [String: Any] = [:]
    touch["isWorkloadPreparation"] = true
    touch["writer"] = "host stores through the Mach-mapped arena, every word of every page"
    touch["bytes"] = MachPageGeometry.dataBytes
    touch["pages"] = MachPageGeometry.pageCount
    touch["fillNanos"] = filled - started
    touch["hostReadbackNanos"] = elapsed() - filled
    touch["hostReadbackMismatchedWords"] = mismatches
    counters["firstTouch"] = touch
    memoryRecords["afterFirstTouch"] = memoryJSON()
    try observeDispositions("afterFirstTouch")
    guard mismatches == 0 else { throw Failure.experiment("host canary readback mismatches") }
  }

  /// The guest has already faulted on every candidate. The window below contains only the per-slot
  /// proofs and atomic placeholder replacements between two fixed-size process samples; kernel
  /// walks and formatting follow. Each slot costs two native calls now, so its loop time is not
  /// comparable with v3's bare deallocation loop.
  private func retire(_ candidates: [Int]) throws {
    let arena = try ownedArena()
    var timeline: [MachPageTimelinePoint] = []
    timeline.reserveCapacity(Self.timelinePoints)
    retiredPages = 0
    let processBefore = try? ProcessMemorySnapshot.capture()
    let hostBefore = MachPageHostSample.capture()
    let started = elapsed()
    var failure: Error?
    for (index, slot) in candidates.enumerated() {
      do {
        if index & 127 == 0 { try requireTime("retirement") }
        try arena.retire(slot)
        retiredPages = (retiredPages ?? 0) + 1
      } catch {
        failure = error
        break
      }
    }
    let finished = elapsed()
    let processAfter = try? ProcessMemorySnapshot.capture()
    let hostAfter = MachPageHostSample.capture()
    for index in 0..<Self.timelinePoints {
      timeline.append(timelinePoint())
      if index + 1 == Self.timelinePoints || DispatchTime.now() >= deadline { break }
      usleep(Self.timelineIntervalMicroseconds)
    }

    let retired = retiredPages ?? 0
    var window: [String: Any] = [:]
    window["mechanism"] =
      "per-slot ownership proof, then mach_vm_map(MACH_PORT_NULL, FIXED|OVERWRITE, PROT_NONE)"
    window["candidatePages"] = candidates.count
    window["retiredPages"] = retired
    window["retiredBytes"] = retired * MachPageGeometry.pageSize
    window["retirementLoopNanos"] = finished - started
    window["residentBytesBefore"] = MachPageJSON.orNull(processBefore?.residentBytes)
    window["residentBytesAfter"] = MachPageJSON.orNull(processAfter?.residentBytes)
    window["residentBytesDelta"] = MachPageJSON.delta(
      processBefore?.residentBytes, processAfter?.residentBytes)
    window["physicalFootprintBefore"] = MachPageJSON.orNull(processBefore?.physicalFootprintBytes)
    window["physicalFootprintAfter"] = MachPageJSON.orNull(processAfter?.physicalFootprintBytes)
    window["physicalFootprintDelta"] = MachPageJSON.delta(
      processBefore?.physicalFootprintBytes, processAfter?.physicalFootprintBytes)
    window["hostCountersBefore"] = MachPageJSON.orNull(hostBefore?.json)
    window["hostCountersAfter"] = MachPageJSON.orNull(hostAfter?.json)
    window["hostFreePagesDeltaUnattributed"] = MachPageJSON.delta(hostBefore?.free, hostAfter?.free)
    window["timelineIntervalMicroseconds"] = Int(Self.timelineIntervalMicroseconds)
    window["timeline"] = timeline.map(\.json)
    window["retiredObjectIdentifierSamples"] =
      candidates.prefix(4).map { MachPageJSON.hex(arena.retiredObjectIDs[$0]) }
    counters["retirement"] = window
    if let failure {
      // A refusal must leave the kernel's own view showing what was and was not replaced. After
      // the deadline no further native work is added; teardown is not gated by it.
      if !deadlineExpired { _ = try? observeEntries("afterRetireFailure") }
      throw failure
    }

    let entries = try observeEntries("afterRetire")
    // The first observation of each placeholder is recorded here; every later proof reproduces it.
    let audit = arena.auditPlaceholders(candidates, entries: entries, record: true)
    // Placeholders are fresh anonymous maps, so only non-placeholder entries can still show a
    // retired identifier. The ledger is evidence only; identifiers are recycled.
    let live = Set(
      entries.filter { $0.tag != MachPageGeometry.placeholderTag }.map(\.objectID))
    let holes = arena.absentCount(candidates, entries: entries)
    let stillMapped = candidates.filter { live.contains(arena.retiredObjectIDs[$0]) }.count
    let neighbourMismatches = arena.neighborMismatches(entries: entries)
    var hostMismatches = 0
    for slot in 0..<MachPageGeometry.pageCount where !MachPageGeometry.isCandidate(slot) {
      if slot & 127 == 0 { try requireTime("neighbour canary check") }
      hostMismatches += try arena.hostMismatches(slot: slot, zero: false)
    }
    var checks: [String: Any] = [:]
    checks["candidatePlaceholdersVerified"] = audit.verified
    checks["candidatePlaceholdersRefused"] = audit.refused
    checks["placeholderRefusalExamples"] = audit.examples
    checks["candidateHolesInKernelWalk"] = holes
    checks["candidateOldObjectsStillMappedInArena"] = stillMapped
    checks["neighbourIdentityMismatches"] = neighbourMismatches
    checks["neighbourHostCanaryMismatchedWords"] = hostMismatches
    counters["retirementChecks"] = checks
    memoryRecords["afterRetire"] = memoryJSON()
    try observeDispositions("afterRetireLivePagesOnly")
    guard audit.refused == 0, holes == 0, neighbourMismatches == 0, hostMismatches == 0 else {
      throw Failure.experiment(
        "post-retirement checks: placeholders refused \(audit.refused), holes \(holes), "
          + "identity \(neighbourMismatches), canary \(hostMismatches)")
    }
  }

  private func refill(_ candidates: [Int]) throws {
    let arena = try ownedArena()
    let walk = try arena.entries()
    // Every retired slot must still be exactly the placeholder recorded for it. Each slot is
    // proven again immediately before its overwrite; this walk is the bulk fail-fast.
    let audit = arena.auditPlaceholders(candidates, entries: walk, record: false)
    counters["placeholdersBeforeRefill"] = audit.json
    guard audit.refused == 0 else {
      throw Failure.experiment(
        "refill: \(audit.refused) retired slots are not their recorded placeholders")
    }
    let retiredIdentities = Set(candidates.map { arena.retiredObjectIDs[$0] })
    let started = elapsed()
    for (index, slot) in candidates.enumerated() {
      if index & 127 == 0 { try requireTime("refill") }
      try arena.refill(slot)
    }
    let finished = elapsed()
    let entries = try observeEntries("afterRefill")
    let reused = try arena.verifyRefilled(entries, slots: candidates, retired: retiredIdentities)
    let neighbourMismatches = arena.neighborMismatches(entries: entries)
    var result: [String: Any] = [:]
    result["pages"] = candidates.count
    result["bytes"] = candidates.count * MachPageGeometry.pageSize
    result["freshObjectsPerPage"] = 1
    result["mapFlags"] = "FIXED|OVERWRITE only after a per-slot placeholder proof"
    result["userTag"] = Int(MachPageGeometry.dataTag)
    result["elapsedNanos"] = finished - started
    result["identifiersReusedFromRetiredObjects"] = reused
    result["neighbourIdentityMismatches"] = neighbourMismatches
    counters["refill"] = result
    memoryRecords["afterRefill"] = memoryJSON()
    // No host store touched the fresh pages; this shows whether they are still cold before the
    // guest first reads them.
    try observeDispositions("afterRefillBeforeGuestRead")
    guard neighbourMismatches == 0 else {
      throw Failure.experiment("refill changed \(neighbourMismatches) neighbour identities")
    }
  }

  private func verifyRefill(_ candidates: [Int], _ neighbours: [Int]) throws {
    let arena = try ownedArena()
    let last = MachPageGeometry.wordsPerPage - 1
    try guestPass("refilledFirstWord", slots: candidates, word: 0, expecting: .zero)
    try guestPass("refilledLastWord", slots: candidates, word: last, expecting: .zero)
    try guestPass("neighboursAfterRefill", slots: neighbours, word: last / 2, expecting: .canary)
    var zeroMismatches = 0
    var canaryMismatches = 0
    for (index, slot) in candidates.enumerated() {
      if index & 127 == 0 { try requireTime("refilled zero check") }
      zeroMismatches += try arena.hostMismatches(slot: slot, zero: true)
    }
    for (index, slot) in neighbours.enumerated() {
      if index & 127 == 0 { try requireTime("neighbour canary check") }
      canaryMismatches += try arena.hostMismatches(slot: slot, zero: false)
    }
    var host: [String: Any] = [:]
    host["refilledNonZeroWords"] = zeroMismatches
    host["neighbourCanaryMismatchedWords"] = canaryMismatches
    counters["hostVerifyAfterRefill"] = host
    memoryRecords["afterRefillVerify"] = memoryJSON()
    try observeDispositions("afterRefillVerify")
    _ = try observeEntries("afterRefillVerify")
    guard zeroMismatches == 0, canaryMismatches == 0 else {
      throw Failure.experiment(
        "host verification: zero \(zeroMismatches), canary \(canaryMismatches)")
    }
  }

  /// Ownership order: vCPU first, then retained aliases, guest mappings and host memory (the
  /// arena tries every one and reports each failure), then the code page and VM. If the vCPU
  /// destroy is not confirmed nothing is unmapped, dropped or freed; the process retires.
  private func teardown() {
    currentStage = "teardown"
    counters["totalVCPURuns"] = MachPageJSON.orNull(guest?.runs)
    if let cpu = machine.cpu {
      let code = hv_vcpu_destroy(cpu)
      cleanup["vcpuDestroyCode"] = Int(code)
      guard code == HV_SUCCESS else {
        // Aliases, placeholders and objects all stay mapped; process exit is the only release.
        cleanup["aliasesKeptForProcessRetirement"] = arena?.aliases.count ?? 0
        retirement = "hv_vcpu_destroy returned \(code); no mapping was touched"
        return
      }
      machine.cpu = nil
      machine.exitInfo = nil
      guest = nil
    }
    if let arena {
      let release = arena.release()
      cleanup["arenaRelease"] = release.json
      cleanupErrors.append(contentsOf: release.errors)
      if !arena.released && release.errors.isEmpty {
        cleanupErrors.append("arena release incomplete: \(release.hostSkipped) pages skipped")
      }
    }
    let closeErrors = machine.close()
    cleanup["machineCloseErrors"] = closeErrors
    cleanupErrors.append(contentsOf: closeErrors)
    cleanup["vmRemains"] = machine.created
  }

  private static let hypothesis =
    "HYPOTHESIS, not fact, PENDING parent hardware proof and review: independent 16KiB named "
    + "Mach objects in one contiguous host virtual range let one host page be physically "
    + "retired without keeping the unmapped page inside a larger still-live VM object."

  private static let interpretation = [
    "retiredBytes counts successful atomic replacements of a slot's object mapping by an "
      + "inaccessible placeholder, each taken only after a per-slot ownership proof made "
      + "immediately before it. ownedRetiredBytes is set only if, in addition, the kernel later "
      + "reported every one of those slots as its own placeholder, a non-overwriting claim of a "
      + "placeholder was refused, every guest read of them faulted before and after, and every "
      + "neighbour kept its object, host canary and guest canary. Both are virtual-range "
      + "ownership, not physical release; the range is never deallocated or left unclaimed "
      + "while the experiment runs.",
    "Resident bytes, task footprint, page dispositions and host counters are accounting "
      + "views. None of them shows that a frame reached a global free list, so "
      + "physicalReleasedBytes and hostFreeListDelta stay null.",
    "In the single profile the retired offsets stay inside one live shared object "
      + "(candidateOldObjectsStillMappedInArena equals the candidate count). Its ownership "
      + "proof cannot enforce a reference count, so passing it never shows that a retired "
      + "offset held the last reference. Read it only against the per-page profiles.",
    "Tags, protections and object identifiers detect accidents. Identifiers are recycled, so "
      + "none proves identity alone, and none is protection against hostile code in this task.",
    "pages-aliased and pages-pre-free-aliased are negative modes. Each is determinate only "
      + "when it is refused at its expected operation and stage with no backing retired; a "
      + "negative run that completes or stops elsewhere is indeterminate, never a pass.",
    "One synthetic 64MiB run on one host is not a Linux, ClickHouse or distribution result.",
  ]

  private static let unknowns = [
    "Whether any retired page reached the global free list: not observable from this process.",
    "How XNU accounts footprint for unmapped pages of a live shared object.",
    "Whether the single profile's object keeps its unmapped pages: inferred from object "
      + "liveness only.",
    "Whether the placeholder overwrite drops the old object's mapping reference inside the "
      + "same kernel call: inferred from kernel behaviour, visible here only through later "
      + "entry state and identifier reuse.",
    "Whether a placeholder stays unclaimed against concurrent allocators or fixed mappings: only "
      + "an owner-thread claim control ran.",
    "Behavior under memory pressure, compression or swap, beyond what the paged-out counters "
      + "show.",
    "Kernel and stage-2 cost of one map entry per 16KiB at larger sizes (131072 per 2GiB).",
    "One host, one OS build, one run; not a distribution.",
  ]

  private static let notExecuted = [
    "Linux kernel, initramfs, disks or any NIC: one synthetic EL1 vCPU only",
    "classic or free-page-reporting balloon, or guest-driven PFN ownership",
    "SMP, hv_vcpus_exit, timers or any second thread",
    "host memory pressure, forced compression, purge, warming or allocator changes",
    "DMA, virtio or any device access to the arena",
    "a second thread or allocator competing for a retired range, or an alias made by one",
    "repeated runs, soak, contention, power events",
    "adoption into NativeLinuxVMM or PageMemory; the 2ms CPUGroup cadence is untouched",
  ]

  private func geometryJSON() -> [String: Any] {
    var geometry: [String: Any] = [:]
    geometry["hostPageSizeBytes"] = MachPageGeometry.pageSize
    geometry["dataBytes"] = MachPageGeometry.dataBytes
    geometry["slots"] = MachPageGeometry.pageCount
    geometry["dataGuestPhysicalBase"] = MachPageJSON.hex(MachPageGeometry.dataGPA)
    geometry["codeGuestPhysicalBase"] = MachPageJSON.hex(MachPageGeometry.codeGPA)
    geometry["retirementPattern"] = "odd-numbered 16KiB slots: 2048 pages, 33554432 bytes"
    geometry["vcpuCount"] = 1
    geometry["nics"] = 0
    return geometry
  }

  private func fixtureJSON() -> [String: Any] {
    var fixture: [String: Any] = [:]
    fixture["instructionWords"] = MachPageGuest.words.map { MachPageJSON.hex(UInt64($0)) }
    fixture["disassembly"] = ["ldr x2, [x1]", "hvc #0"]
    fixture["entryCPSR"] = MachPageJSON.hex(MachPageGuest.entryCPSR)
    fixture["entrySentinelX2"] = MachPageJSON.hex(MachPageGuest.sentinel)
    fixture["hypercallSelectorX0"] = "0x41"
    fixture["expectedHvcExitPC"] = MachPageJSON.hex(MachPageGuest.exitPC)
    fixture["expectedFault"] =
      "EC 0x24, syndrome & 0x3c == 0x04 (translation), WnR 0, same 4KiB frame, PC unchanged"
    fixture["codeSetup"] =
      "RW load, sys_icache_invalidate, hv_vm_protect R+X before the vCPU exists, host "
      + "mach_vm_protect R, instruction-word read-back"
    fixture["guestTranslation"] = "SCTLR_EL1 and VBAR_EL1 are not written by this experiment"
    return fixture
  }

  private func buildJSON() -> [String: Any] {
    var json: [String: Any] = [:]
    json["mode"] = "mach-page-objects"
    json["schema"] = 2
    json["profile"] = profile.rawValue
    json["retirementMechanism"] =
      "placeholder: per-slot ownership proof, then mach_vm_map(MACH_PORT_NULL, FIXED|OVERWRITE, "
      + "PROT_NONE) over the slot; v3 evidence (schema 1) used deallocate, which left holes"
    json["status"] =
      "private research experiment; architecture and hypothesis PENDING parent review; not a "
      + "qualification; all five product gates remain OPEN; nothing is adopted by "
      + "NativeLinuxVMM or PageMemory"
    json["confidence"] =
      "low: one synthetic run of one profile on one host; accounting views only, no repetition"
    json["scope"] =
      "one synthetic EL1 vCPU, no NIC, no Linux, no disk; a 64MiB private Mach arena; not a "
      + "Linux, ClickHouse or balloon result"
    json["hypothesis"] = Self.hypothesis
    json["geometry"] = geometryJSON()
    json["fixture"] = fixtureJSON()
    json["hostDeadlineSeconds"] = MachPageObjects.deadlineSeconds
    json["hostDeadlineExpired"] = deadlineExpired
    json["elapsedNanos"] = elapsed()
    json["outcome"] = outcome
    json["determinate"] = determinate
    json["negativeControl"] = MachPageJSON.orNull(
      expectedRefusal.map { expected in
        [
          "expectedOperation": expected.operation, "expectedStage": expected.stage,
          "held": negativeControlHeld ?? false,
        ] as [String: Any]
      })
    json["stageAtEnd"] = stageAtEnd
    json["phases"] = phases
    json["primaryError"] = primary
    json["refusal"] = MachPageJSON.orNull(
      refused.map { refusal in
        [
          "operation": refusal.operation,
          "nativeCode": MachPageJSON.orNull(refusal.code.map { Int($0) }),
          "detail": refusal.detail, "stage": refusal.stage,
        ] as [String: Any]
      })
    json["vmCreateCode"] = MachPageJSON.orNull(vmCreateCode)
    json["cleanupErrors"] = cleanupErrors
    json["cleanup"] = cleanup
    json["processRetired"] = retirement != nil
    json["processRetirementReason"] = MachPageJSON.orNull(retirement)
    json["kernelEntries"] = entryRecords
    json["pageDispositions"] = dispositionRecords
    json["processMemory"] = memoryRecords
    json["guestChecks"] = guestRecords
    json["counters"] = counters
    json["retiredBytes"] = MachPageJSON.orNull(retiredPages.map { $0 * MachPageGeometry.pageSize })
    json["ownedRetiredBytes"] = MachPageJSON.orNull(
      ownedRetiredPages.map { $0 * MachPageGeometry.pageSize })
    json["physicalReleasedBytes"] = NSNull()
    json["hostFreeListDelta"] = NSNull()
    json["interpretation"] = Self.interpretation
    json["unknowns"] = Self.unknowns
    json["notExecuted"] = Self.notExecuted
    return json
  }

  /// Bounded JSON: pretty, then compact, then without the bulkiest sections, then a stub.
  func evidence() -> Data {
    var json = buildJSON()
    for attempt in 0..<3 {
      if attempt == 2 {
        json["evidenceReduced"] = true
        json.removeValue(forKey: "kernelEntries")
        json.removeValue(forKey: "phases")
      }
      let options: JSONSerialization.WritingOptions =
        attempt == 0 ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
      guard JSONSerialization.isValidJSONObject(json),
        let data = try? JSONSerialization.data(withJSONObject: json, options: options)
      else { break }
      if data.count <= EvidenceFile.maximumBytes { return data }
    }
    return Data("{\"mode\":\"mach-page-objects\",\"schema\":2,\"evidenceError\":true}".utf8)
  }
}

/// Early private CLI mode: `hvf-memory-lab mach-page-objects <new-result.json> <profile>` with
/// `single`, `pages`, or the negative modes `pages-aliased` and `pages-pre-free-aliased`.
enum MachPageObjects {
  static let deadlineSeconds = 15

  /// Exit status: 0 for a determinate finding (completed, or a recorded native refusal; for a
  /// negative mode only its expected refusal) with every cleanup verified; 1 for a refused output
  /// path, an invalid or indeterminate run; 2 after process retirement because a vCPU destroy
  /// could not be confirmed.
  static func run(output path: String, profile: MachPageProfile) throws {
    let file = try EvidenceFile.reserve(path)
    let deadline = DispatchTime.now() + .seconds(deadlineSeconds)
    let experiment = MachPageExperiment(profile: profile, deadline: deadline)
    experiment.execute()
    let data = experiment.evidence()
    if let retired = experiment.retirement {
      // The vCPU may still exist: keep the evidence, unmap nothing, let process exit retire it.
      do { try file.finish(data) } catch { print("HVF_MACH_PAGE_EVIDENCE_FAIL \(error)") }
      print("HVF_MACH_PAGE_RETIRE \(retired)")
      fflush(nil)
      _exit(2)
    }
    try file.finish(data)
    guard experiment.determinate else { throw Failure.experiment(experiment.summary) }
    print("HVF_MACH_PAGE_OBJECTS_COMPLETE profile=\(profile.rawValue) \(experiment.outcome)")
  }
}
