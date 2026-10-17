import Darwin
import Dispatch
import Foundation
import Hypervisor
import PageMemory
import Synchronization

// Internal to this executable target only, so the private Mach page-object experiment can reuse
// the reviewed VM/code-page ownership. Nothing here is exported by a library product.
enum Failure: Error {
  case arguments, state, geometry, mismatch, observation
  case native(String, Int32)
  case guestResult(UInt64)
  case aliased(UInt32)
  case experiment(String)
}

func check(_ code: hv_return_t, _ operation: String) throws {
  guard code == HV_SUCCESS else { throw Failure.native(operation, code) }
}

// Private to the finite, synchronous lab. No pointer or mapping escapes to a caller.
final class Region {
  let address: UInt64
  let size: Int
  var pointer: UnsafeMutableRawPointer?
  var mapped = false
  init(address: UInt64, size: Int) {
    self.address = address
    self.size = size
  }
}

final class Machine {
  var created = false
  var cpu: hv_vcpu_t?
  var exitInfo: UnsafeMutablePointer<hv_vcpu_exit_t>?
  var running = false
  var regions: [Region] = []
  var alias: (address: UInt64, size: Int)?
  let pageSize = Int(sysconf(Int32(_SC_PAGESIZE)))
  let thread = pthread_self()

  func confined() throws {
    guard pthread_equal(thread, pthread_self()) != 0, !running else { throw Failure.state }
  }

  func allocate(address: UInt64, size: Int) throws -> Region {
    try confined()
    guard created, pageSize == 16384, size > 0, size <= 64 << 20,
      size % pageSize == 0, address % UInt64(pageSize) == 0,
      address <= UInt64.max - UInt64(size),
      regions.allSatisfy({
        $0.pointer == nil || address + UInt64(size) <= $0.address
          || $0.address + UInt64($0.size) <= address
      })
    else { throw Failure.geometry }
    let region = Region(address: address, size: size)
    try check(hv_vm_allocate(&region.pointer, size, 0), "allocate")
    regions.append(region)
    guard let pointer = region.pointer else { throw Failure.state }
    try check(
      hv_vm_map(
        pointer, address, size,
        UInt64(HV_MEMORY_READ | HV_MEMORY_WRITE)), "map")
    region.mapped = true
    return region
  }

  func unmap(_ region: Region) throws {
    try confined()
    guard regions.contains(where: { $0 === region }), region.mapped,
      region.pointer != nil
    else { throw Failure.state }
    try check(hv_vm_unmap(region.address, region.size), "unmap")
    region.mapped = false
  }

  func remap(_ region: Region) throws {
    try confined()
    guard regions.contains(where: { $0 === region }), !region.mapped,
      let pointer = region.pointer
    else { throw Failure.state }
    try check(
      hv_vm_map(
        pointer, region.address, region.size,
        UInt64(HV_MEMORY_READ | HV_MEMORY_WRITE)), "remap")
    region.mapped = true
  }

  func release(_ region: Region) throws {
    try confined()
    guard regions.contains(where: { $0 === region }), !region.mapped,
      let pointer = region.pointer
    else { throw Failure.state }
    try requireExclusive(region)
    try check(hv_vm_deallocate(pointer, region.size), "deallocate")
    region.pointer = nil
  }

  enum Fault { case translation, permission }

  func execute(
    data: Region, operation: UInt64, salt: UInt64, fault: Fault? = nil, offset: UInt64 = 0
  ) throws {
    try confined()
    guard let cpu, let exitInfo, offset < UInt64(data.size), offset % 4096 == 0
    else { throw Failure.state }
    for (reg, value) in [
      (HV_REG_PC, UInt64(0x100000)), (HV_REG_CPSR, 0x3c5),
      (HV_REG_X0, data.address + offset), (HV_REG_X1, UInt64(data.size / 4096)), (HV_REG_X2, salt),
      (HV_REG_X3, operation),
    ] {
      try check(hv_vcpu_set_reg(cpu, reg, value), "set-register")
    }
    try check(hv_vcpu_set_sys_reg(cpu, HV_SYS_REG_SP_EL1, 0x220000), "set-stack")
    try check(hv_vcpu_set_sys_reg(cpu, HV_SYS_REG_CPACR_EL1, 3 << 20), "enable-fp")
    running = true
    let code = hv_vcpu_run(cpu)
    running = false
    try check(code, "run")
    let event = exitInfo.pointee
    guard event.reason == HV_EXIT_REASON_EXCEPTION else { throw Failure.mismatch }
    if let fault {
      let status: UInt64 = fault == .translation ? 0x04 : 0x0c
      guard event.exception.syndrome >> 26 == 0x24,
        event.exception.syndrome & 0x3c == status,
        event.exception.physical_address == data.address + offset
      else { throw Failure.mismatch }
    } else {
      var value: UInt64 = .max
      try check(hv_vcpu_get_reg(cpu, HV_REG_X0, &value), "guest-result")
      guard event.exception.syndrome >> 26 == 0x16 else { throw Failure.mismatch }
      guard value == 0 else { throw Failure.guestResult(value) }
    }
  }

  // Kernel page flags concern this owned allocation, never a guessed VZ helper PID.
  func resident(_ region: Region) throws -> UInt64 {
    try confined()
    guard let pointer = region.pointer else { throw Failure.state }
    func setting(_ name: String) throws -> Int32 {
      var value: Int32 = 0
      var count = MemoryLayout<Int32>.size
      guard sysctlbyname(name, &value, &count, nil, 0) == 0,
        count == MemoryLayout<Int32>.size
      else { throw Failure.observation }
      return value
    }
    let geometry = try setting("vm.self_region_page_size")
    guard geometry == 1 || geometry == pageSize,
      try setting("vm.self_region_footprint") == 0
    else { throw Failure.geometry }
    var present: UInt64 = 0
    try withUnsafeTemporaryAllocation(of: integer_t.self, capacity: 256) { scratch in
      for offset in stride(from: 0, to: region.size, by: 255 * pageSize) {
        scratch.initialize(repeating: .min)
        let bytes = min(region.size - offset, 255 * pageSize)
        let expected = bytes / pageSize
        var count = UInt64(expected + 1)
        try check(
          mach_vm_page_range_query(
            mach_task_self_,
            UInt64(UInt(bitPattern: pointer.advanced(by: offset))), UInt64(bytes),
            UInt64(UInt(bitPattern: scratch.baseAddress!)), &count), "page-query")
        guard count == expected else { throw Failure.observation }
        for index in 0..<expected {
          let flags = scratch[index]
          let invalid =
            VM_PAGE_QUERY_PAGE_PAGED_OUT | VM_PAGE_QUERY_PAGE_FICTITIOUS
            | VM_PAGE_QUERY_PAGE_COPIED | VM_PAGE_QUERY_PAGE_EXTERNAL
          guard flags != .min, flags & invalid == 0 else {
            throw Failure.observation
          }
          if flags & VM_PAGE_QUERY_PAGE_PRESENT != 0 { present += 1 }
        }
      }
    }
    guard try setting("vm.self_region_page_size") == geometry,
      try setting("vm.self_region_footprint") == 0
    else { throw Failure.geometry }
    return present * UInt64(pageSize)
  }

  func backingInfo(_ region: Region) throws -> vm_region_submap_info_data_64_t {
    try confined()
    guard let pointer = region.pointer else { throw Failure.state }
    var start = UInt64(UInt(bitPattern: pointer))
    let original = start
    var length: UInt64 = 0
    var depth: UInt32 = 0
    var info = vm_region_submap_info_data_64_t()
    let capacity =
      MemoryLayout<vm_region_submap_info_data_64_t>.size
      / MemoryLayout<integer_t>.size
    var count = mach_msg_type_number_t(capacity)
    let code = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
        mach_vm_region_recurse(mach_task_self_, &start, &length, &depth, $0, &count)
      }
    }
    try check(code, "backing-info")
    guard count == capacity, start == original, length >= region.size,
      info.is_submap == 0, info.shadow_depth == 0, info.external_pager == 0,
      info.object_id_full != 0, info.pages_swapped_out == 0,
      info.pages_wired == 0, info.user_wired_count == 0
    else { throw Failure.observation }
    return info
  }

  func requireExclusive(_ region: Region) throws {
    let info = try backingInfo(region)
    guard info.ref_count == 1 else { throw Failure.aliased(info.ref_count) }
  }

  func makeAlias(_ region: Region) throws {
    try confined()
    guard alias == nil, let pointer = region.pointer else { throw Failure.state }
    var address: UInt64 = 0
    var current: vm_prot_t = 0
    var maximum: vm_prot_t = 0
    try check(
      mach_vm_remap(
        mach_task_self_, &address, UInt64(region.size), 0,
        VM_FLAGS_ANYWHERE, mach_task_self_, UInt64(UInt(bitPattern: pointer)), 0,
        &current, &maximum, VM_INHERIT_NONE), "make-alias")
    alias = (address, region.size)
  }

  func dropAlias() throws {
    try confined()
    guard let alias else { throw Failure.state }
    try check(mach_vm_deallocate(mach_task_self_, alias.address, UInt64(alias.size)), "drop-alias")
    self.alias = nil
  }

  func requireAbsent(address: UInt64, size: Int) throws {
    var start = address
    var length: UInt64 = 0
    var info = vm_region_basic_info_data_64_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_region_basic_info_data_64_t>.size / MemoryLayout<integer_t>.size)
    var port: mach_port_t = 0
    let code = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        mach_vm_region(
          mach_task_self_, &start, &length,
          VM_REGION_BASIC_INFO_64, $0, &count, &port)
      }
    }
    if port != 0 {
      try check(mach_port_deallocate(mach_task_self_, port), "release-region-port")
    }
    guard
      code == KERN_INVALID_ADDRESS
        || (code == KERN_SUCCESS
          && start >= address + UInt64(size))
    else { throw Failure.observation }
  }

  func close() -> [String] {
    var errors: [String] = []
    do { try confined() } catch { return [String(describing: error)] }
    if let cpu {
      let code = hv_vcpu_destroy(cpu)
      guard code == HV_SUCCESS else { return ["vcpu-destroy \(code)"] }
      self.cpu = nil
      exitInfo = nil
    }
    if alias != nil {
      do { try dropAlias() } catch { errors.append(String(describing: error)) }
    }
    for region in regions.reversed() {
      if region.mapped {
        do { try unmap(region) } catch {
          errors.append(String(describing: error))
          continue
        }
      }
      if region.pointer != nil {
        do { try release(region) } catch { errors.append(String(describing: error)) }
      }
    }
    if created {
      let code = hv_vm_destroy()
      if code == HV_SUCCESS { created = false } else { errors.append("vm-destroy \(code)") }
    }
    return errors
  }
}

// Exclusive, no-follow evidence output. The kernel refuses every existing path (file, directory,
// symlink, dangling symlink), and the descriptor is closed exactly once with checked results.
final class EvidenceFile {
  static let maximumBytes = 64 << 10
  private var descriptor: Int32

  private init(descriptor: Int32) { self.descriptor = descriptor }

  static func reserve(_ path: String) throws -> EvidenceFile {
    guard !path.isEmpty else { throw Failure.arguments }
    let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw Failure.native("output-reserve", errno) }
    return EvidenceFile(descriptor: descriptor)
  }

  func finish(_ data: Data) throws {
    guard descriptor >= 0 else { throw Failure.state }
    let descriptor = self.descriptor
    self.descriptor = -1
    var failure: Failure?
    if data.isEmpty || data.count > Self.maximumBytes {
      failure = .experiment("evidence size \(data.count)")
    } else {
      data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
          let count = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
          if count < 0, errno == EINTR { continue }
          guard count > 0 else {
            failure = .native("output-write", count < 0 ? errno : EIO)
            return
          }
          offset += count
        }
      }
    }
    let closed = close(descriptor)
    if let failure { throw failure }
    guard closed == 0 else { throw Failure.native("output-close", errno) }
  }
}

private enum RunClass: String, Sendable {
  case guestHVC = "guest-hvc-marker"
  case canceledBeforeGuest = "canceled-before-guest-instruction"
  case canceledAfterProgress = "canceled-after-guest-progress"
  case unexpectedExit = "unexpected-exit"
  case observationFailed = "register-observation-failed"
  case runFailed = "run-failed"
}

// Shared state of one pre-entry-wake trial. Every mutable field lives behind one mutex and no
// native call is made while it is held, so the parent can always snapshot the evidence.
// Event sequence numbers are the only ordering evidence; no timestamps are recorded.
private final class TrialChannel: Sendable {
  enum Side: String, Sendable { case parent, worker }
  enum Step: String, Sendable {
    case vcpuCreate = "vcpu-create", vtimerMask = "vtimer-mask"
    case published, setupFailed = "setup-failed"
    case kickBegin = "kick-begin", kickReturned = "kick-returned"
    case gateRelease = "gate-release", gateAbort = "gate-abort"
    case gatePassed = "gate-passed", gateAborted = "gate-aborted", gateTimeout = "gate-timeout"
    case runBegin = "run-begin", followOnBegin = "follow-on-begin"
    case runReturned = "run-returned"
    case vcpuDestroy = "vcpu-destroy", workerFinished = "worker-finished"
  }
  enum Decision: Sendable { case pending, permit, abort }
  enum Gate: String, Sendable {
    case notReached = "not-reached", passed, aborted, timedOut = "timed-out"
  }

  struct Event: Sendable {
    let sequence: Int
    let side: Side
    let step: Step
    let code: Int32?
    let thread: UInt
  }
  struct Readback: Sendable {
    let register: String
    let expected: UInt64
    let observed: UInt64
  }
  struct Run: Sendable {
    var index = 0
    var runCode: Int32 = 0
    var reason: UInt32 = 0
    var syndrome: UInt64?
    var pc: UInt64?
    var x0: UInt64?
    var registerCodes: [Int32] = []
    var beginSequence = 0
    var returnSequence = 0
    var classification = RunClass.runFailed
  }
  struct State: Sendable {
    var events: [Event] = []
    var nextSequence = 1
    var overflow = false
    var createCode: Int32?
    var vcpu: hv_vcpu_t?
    var setupFailure = ""
    var readbacks: [Readback] = []
    var decision = Decision.pending
    var gate = Gate.notReached
    var kickCode: Int32?
    var runs: [Run] = []
    var destroyCode: Int32?
    var joinCode: Int32?
  }

  static let maximumEvents = 64
  let state = Mutex(State())
  let published = DispatchSemaphore(value: 0)
  let gate = DispatchSemaphore(value: 0)
  let finished = DispatchSemaphore(value: 0)
  let deadline: DispatchTime

  init(deadline: DispatchTime) { self.deadline = deadline }

  @discardableResult
  func note(_ side: Side, _ step: Step, _ code: Int32? = nil) -> Int {
    let thread = UInt(bitPattern: pthread_self())
    return state.withLock { state in
      let sequence = state.nextSequence
      state.nextSequence += 1
      if state.events.count < Self.maximumEvents {
        state.events.append(
          Event(sequence: sequence, side: side, step: step, code: code, thread: thread))
      } else {
        state.overflow = true
      }
      return sequence
    }
  }

  func snapshot() -> State { state.withLock { $0 } }
}

// One-vCPU Hypervisor.framework experiment: does hv_vcpus_exit, completed before the first
// hv_vcpu_run, cancel that run before any guest instruction? This is not a wake-path
// qualification: no WFI, SMP, device, timer or concurrent kick is exercised.
private enum PreEntryWake {
  static let deadlineSeconds = 5
  static let maximumRuns = 3
  static let codeAddress: UInt64 = 0x10_0000
  static let codeSize = 16384
  static let marker: UInt64 = 0x5ea7
  static let entryCPSR: UInt64 = 0x3c5
  static let entrySentinel: UInt64 = 0xa5a5_0000_0000_0001
  // movz x0, #0x5ea7 ; hvc #0. HVF reports the PC after the HVC; the zero-filled rest of the
  // page would fault rather than loop if the guest ever ran past it.
  static let words: [UInt32] = [0xd280_0000 | (UInt32(marker) << 5), 0xd400_0002]
  static let expectedExitPC = codeAddress + UInt64(words.count * 4)
}

extension PreEntryWake {
  static func nativeSucceeded(_ code: Int32?) -> Bool {
    guard let code else { return false }
    return code == HV_SUCCESS
  }

  static func classify(_ run: TrialChannel.Run) -> RunClass {
    guard run.runCode == HV_SUCCESS else { return .runFailed }
    guard let pc = run.pc, let x0 = run.x0 else { return .observationFailed }
    if run.reason == HV_EXIT_REASON_CANCELED.rawValue {
      let untouched = pc == codeAddress && x0 == entrySentinel
      return untouched ? .canceledBeforeGuest : .canceledAfterProgress
    }
    if run.reason == HV_EXIT_REASON_EXCEPTION.rawValue, let syndrome = run.syndrome {
      let hvcZero = syndrome >> 26 == 0x16 && syndrome & 0xffff == 0
      if hvcZero && x0 == marker && pc == expectedExitPC { return .guestHVC }
    }
    return .unexpectedExit
  }

  // Sets and reads back the entry state. Returns a failure description, or nil when verified.
  static func configure(_ cpu: hv_vcpu_t, _ channel: TrialChannel) -> String? {
    let maskCode = hv_vcpu_set_vtimer_mask(cpu, true)
    channel.note(.worker, .vtimerMask, maskCode)
    guard maskCode == HV_SUCCESS else { return "vtimer-mask \(maskCode)" }
    for (name, register, value) in [
      ("PC", HV_REG_PC, codeAddress), ("CPSR", HV_REG_CPSR, entryCPSR),
      ("X0", HV_REG_X0, entrySentinel),
    ] {
      let setCode = hv_vcpu_set_reg(cpu, register, value)
      guard setCode == HV_SUCCESS else { return "set \(name) \(setCode)" }
      var observed: UInt64 = 0
      let getCode = hv_vcpu_get_reg(cpu, register, &observed)
      guard getCode == HV_SUCCESS else { return "get \(name) \(getCode)" }
      channel.state.withLock {
        $0.readbacks.append(.init(register: name, expected: value, observed: observed))
      }
      guard observed == value else { return "readback \(name)" }
    }
    return nil
  }

  // Entry point of the one native vCPU thread. Create, configure, run, register reads and
  // destroy all happen here. The parent receives plain values only (the published vCPU
  // identifier, native return codes and register readings), never a vCPU or exit-record pointer.
  static func worker(_ channel: TrialChannel) {
    var cpu: hv_vcpu_t = 0
    var exitInfo: UnsafeMutablePointer<hv_vcpu_exit_t>?
    let createCode = hv_vcpu_create(&cpu, &exitInfo, nil)
    channel.note(.worker, .vcpuCreate, createCode)
    var failure = ""
    if createCode != HV_SUCCESS {
      failure = "vcpu-create \(createCode)"
    } else if exitInfo == nil {
      failure = "vcpu-create returned no exit record"
    } else if let problem = configure(cpu, channel) {
      failure = problem
    }
    channel.state.withLock {
      $0.createCode = createCode
      if createCode == HV_SUCCESS { $0.vcpu = cpu }
      $0.setupFailure = failure
    }
    channel.note(.worker, failure.isEmpty ? .published : .setupFailed)
    channel.published.signal()
    if failure.isEmpty, let exitInfo { enter(cpu, exitInfo, channel) }
    if createCode == HV_SUCCESS {
      let destroyCode = hv_vcpu_destroy(cpu)
      channel.state.withLock { $0.destroyCode = destroyCode }
      channel.note(.worker, .vcpuDestroy, destroyCode)
    }
    channel.note(.worker, .workerFinished)
    channel.finished.signal()
  }

  // Waits for the parent's permit under the single host deadline, then runs the guest. No vCPU
  // call separates the parent's kick from the first hv_vcpu_run. Only a cancellation observed
  // before any guest instruction leads to a bounded follow-on run.
  static func enter(
    _ cpu: hv_vcpu_t, _ exitInfo: UnsafeMutablePointer<hv_vcpu_exit_t>, _ channel: TrialChannel
  ) {
    guard channel.gate.wait(timeout: channel.deadline) == .success else {
      channel.state.withLock { $0.gate = .timedOut }
      channel.note(.worker, .gateTimeout)
      return
    }
    guard channel.state.withLock({ $0.decision }) == .permit else {
      channel.state.withLock { $0.gate = .aborted }
      channel.note(.worker, .gateAborted)
      return
    }
    channel.state.withLock { $0.gate = .passed }
    channel.note(.worker, .gatePassed)
    for index in 0..<maximumRuns {
      var run = TrialChannel.Run()
      run.index = index
      run.beginSequence = channel.note(.worker, index == 0 ? .runBegin : .followOnBegin)
      run.runCode = hv_vcpu_run(cpu)
      run.returnSequence = channel.note(.worker, .runReturned, run.runCode)
      if run.runCode == HV_SUCCESS {
        let event = exitInfo.pointee
        run.reason = event.reason.rawValue
        if event.reason == HV_EXIT_REASON_EXCEPTION { run.syndrome = event.exception.syndrome }
        var pc: UInt64 = 0
        var x0: UInt64 = 0
        let pcCode = hv_vcpu_get_reg(cpu, HV_REG_PC, &pc)
        let x0Code = hv_vcpu_get_reg(cpu, HV_REG_X0, &x0)
        run.registerCodes = [pcCode, x0Code]
        if pcCode == HV_SUCCESS { run.pc = pc }
        if x0Code == HV_SUCCESS { run.x0 = x0 }
      }
      run.classification = classify(run)
      let record = run
      channel.state.withLock { $0.runs.append(record) }
      guard run.classification == .canceledBeforeGuest else { return }
    }
  }
}

private struct TrialOutcome {
  let name: String
  let kick: Bool
  var vmCreateCode: Int32?
  var vmCreated = false
  var vmRemains = false
  var parentError = ""
  var cleanupErrors: [String] = []
  var retire: String?
  var snapshot = TrialChannel.State()
  var invalid: [String] = []
  var valid: Bool { invalid.isEmpty }
  var firstRun: RunClass? { snapshot.runs.first?.classification }
}

extension PreEntryWake {
  // Same sequence as the reviewed lab: guest RW while loading, R+X before any vCPU exists, the
  // host alias read-only, then a read-back of the instruction words.
  static func prepareCode(_ vm: Machine) throws {
    let code = try vm.allocate(address: codeAddress, size: codeSize)
    guard let pointer = code.pointer else { throw Failure.state }
    for (index, word) in words.enumerated() {
      pointer.storeBytes(of: word.littleEndian, toByteOffset: index * 4, as: UInt32.self)
    }
    sys_icache_invalidate(pointer, code.size)
    try check(
      hv_vm_protect(code.address, code.size, UInt64(HV_MEMORY_READ | HV_MEMORY_EXEC)),
      "protect-code-rx")
    try check(
      mach_vm_protect(
        mach_task_self_, UInt64(UInt(bitPattern: pointer)), UInt64(code.size), 0, VM_PROT_READ),
      "protect-code-host-ro")
    for (index, word) in words.enumerated() {
      let stored = pointer.load(fromByteOffset: index * 4, as: UInt32.self)
      guard UInt32(littleEndian: stored) == word else { throw Failure.observation }
    }
  }

  static func spawn(_ channel: TrialChannel) throws -> pthread_t {
    let context = Unmanaged.passRetained(channel).toOpaque()
    var thread: pthread_t?
    let code = pthread_create(
      &thread, nil,
      { raw in
        PreEntryWake.worker(Unmanaged<TrialChannel>.fromOpaque(raw).takeRetainedValue())
        return nil
      }, context)
    guard code == 0 else {
      Unmanaged<TrialChannel>.fromOpaque(context).release()
      throw Failure.native("pthread-create", code)
    }
    // pthread_create stores the identifier on success.
    return thread!
  }

  // Returns a retirement reason unless the worker was observed finished and joined. The parent
  // never touches the vCPU except for hv_vcpus_exit with the identifier the worker published.
  static func drive(_ channel: TrialChannel, thread: pthread_t, kick: Bool) -> String? {
    guard channel.published.wait(timeout: channel.deadline) == .success else {
      return "worker did not publish before the host deadline"
    }
    let published = channel.snapshot()
    if published.setupFailure.isEmpty {
      var decision = TrialChannel.Decision.abort
      if let vcpu = published.vcpu {
        decision = .permit
        if kick {
          var identifier = vcpu
          channel.note(.parent, .kickBegin)
          let code = hv_vcpus_exit(&identifier, 1)
          channel.state.withLock { $0.kickCode = code }
          channel.note(.parent, .kickReturned, code)
          if code != HV_SUCCESS { decision = .abort }
        }
      }
      channel.state.withLock { $0.decision = decision }
      channel.note(.parent, decision == .permit ? .gateRelease : .gateAbort)
      channel.gate.signal()
    }
    guard channel.finished.wait(timeout: channel.deadline) == .success else {
      return "worker did not finish before the host deadline"
    }
    let code = pthread_join(thread, nil)
    channel.state.withLock { $0.joinCode = code }
    return code == 0 ? nil : "pthread_join returned \(code)"
  }

  // One independent trial with its own VM and vCPU. Guest memory is released only through
  // Machine.close(), and that refuses to run while Machine.running is set, which stays set
  // until pthread_join has succeeded. An unverified worker therefore leads to retirement.
  static func runTrial(name: String, kick: Bool, deadline: DispatchTime) -> TrialOutcome {
    var outcome = TrialOutcome(name: name, kick: kick)
    let vm = Machine()
    let channel = TrialChannel(deadline: deadline)
    do {
      let createCode = hv_vm_create(nil)
      outcome.vmCreateCode = createCode
      try check(createCode, "vm-create")
      vm.created = true
      outcome.vmCreated = true
      try prepareCode(vm)
      vm.running = true  // A native CPU may exist from here until its thread is joined.
      let thread: pthread_t
      do { thread = try spawn(channel) } catch {
        vm.running = false
        throw error
      }
      outcome.retire = drive(channel, thread: thread, kick: kick)
      if outcome.retire == nil { vm.running = false }
    } catch { outcome.parentError = String(describing: error) }
    let state = channel.snapshot()
    if outcome.retire == nil, nativeSucceeded(state.createCode), !nativeSucceeded(state.destroyCode) {
      outcome.retire = "vCPU destroy was not confirmed"
    }
    if outcome.retire == nil { outcome.cleanupErrors = vm.close() }
    outcome.vmRemains = vm.created
    outcome.snapshot = channel.snapshot()
    judge(&outcome)
    return outcome
  }

  // Validity is derived from native results and recorded event order only.
  static func judge(_ outcome: inout TrialOutcome) {
    let state = outcome.snapshot
    var reasons: [String] = []
    func first(_ step: TrialChannel.Step) -> Int? {
      state.events.first { $0.step == step }?.sequence
    }
    func text(_ code: Int32?) -> String { code.map { String($0) } ?? "absent" }
    if !outcome.parentError.isEmpty { reasons.append("parent error: \(outcome.parentError)") }
    if let retire = outcome.retire { reasons.append("process retirement: \(retire)") }
    if !state.setupFailure.isEmpty { reasons.append("worker setup: \(state.setupFailure)") }
    if state.overflow { reasons.append("event log overflow") }
    let workers = Set(state.events.filter { $0.side == .worker }.map(\.thread))
    let parents = Set(state.events.filter { $0.side == .parent }.map(\.thread))
    if workers.count != 1 || !workers.isDisjoint(with: parents) {
      reasons.append("vCPU events did not share exactly one worker thread distinct from parent")
    }
    if state.gate != .passed { reasons.append("worker gate \(state.gate.rawValue)") }
    if outcome.kick {
      if !nativeSucceeded(state.kickCode) {
        reasons.append("hv_vcpus_exit result \(text(state.kickCode))")
      }
    } else if first(.kickBegin) != nil {
      reasons.append("control trial issued hv_vcpus_exit")
    }
    var chain: [Int?] = [first(.published)]
    if outcome.kick { chain += [first(.kickBegin), first(.kickReturned)] }
    chain += [first(.gateRelease), first(.gatePassed), first(.runBegin)]
    let sequences = chain.compactMap { $0 }
    let ordered = zip(sequences, sequences.dropFirst()).allSatisfy { $0.0 < $0.1 }
    if sequences.count != chain.count || !ordered {
      reasons.append("recorded order does not prove published < kick < permit < first entry")
    }
    let classes = state.runs.map(\.classification)
    if outcome.kick {
      if classes.first == .guestHVC {
        if classes.count != 1 { reasons.append("runs continued after the guest HVC") }
      } else if classes.first == .canceledBeforeGuest {
        if classes.count < 2 || classes.last != .guestHVC {
          reasons.append("guest did not reach HVC after the cancelled first run")
        }
      } else {
        reasons.append("first run after the kick was \(classes.first?.rawValue ?? "absent")")
      }
    } else if classes != [.guestHVC] {
      reasons.append("control did not reach the guest HVC marker in exactly one run")
    }
    if nativeSucceeded(state.createCode), !nativeSucceeded(state.destroyCode) {
      reasons.append("hv_vcpu_destroy result \(text(state.destroyCode))")
    }
    if !state.events.isEmpty, state.joinCode != 0 {
      reasons.append("pthread_join result \(text(state.joinCode))")
    }
    for error in outcome.cleanupErrors { reasons.append("cleanup: \(error)") }
    if outcome.vmRemains { reasons.append("VM was not destroyed") }
    outcome.invalid = reasons
  }
}

extension PreEntryWake {
  struct Verdict {
    var determinate = false
    var latched: Bool?
    var summary = ""
  }

  static func hex(_ value: UInt64) -> String { "0x" + String(value, radix: 16) }

  static func orNull(_ value: Any?) -> Any { value ?? NSNull() }

  static func number(_ value: Int32?) -> Any { orNull(value.map { Int($0) }) }

  static func reasonName(_ reason: UInt32) -> String {
    if reason == HV_EXIT_REASON_CANCELED.rawValue { return "canceled" }
    if reason == HV_EXIT_REASON_EXCEPTION.rawValue { return "exception" }
    return "other(\(reason))"
  }

  static func eventJSON(_ event: TrialChannel.Event) -> [String: Any] {
    [
      "sequence": event.sequence, "side": event.side.rawValue, "step": event.step.rawValue,
      "nativeCode": number(event.code),
    ]
  }

  static func runJSON(_ run: TrialChannel.Run) -> [String: Any] {
    var json: [String: Any] = [
      "index": run.index, "phase": run.index == 0 ? "first" : "follow-on",
      "nativeRunCode": Int(run.runCode), "classification": run.classification.rawValue,
      "beginSequence": run.beginSequence, "returnSequence": run.returnSequence,
      "registerReadCodes": run.registerCodes.map { Int($0) },
      "pc": orNull(run.pc.map(hex)), "x0": orNull(run.x0.map(hex)),
    ]
    if run.runCode == HV_SUCCESS {
      json["exitReasonRaw"] = Int(run.reason)
      json["exitReason"] = reasonName(run.reason)
    }
    if let syndrome = run.syndrome {
      json["syndrome"] = hex(syndrome)
      json["exceptionClass"] = hex(syndrome >> 26)
      json["hvcImmediate"] = hex(syndrome & 0xffff)
    }
    return json
  }

  static func fixtureJSON() -> [String: Any] {
    [
      "instructionWords": words.map { hex(UInt64($0)) },
      "disassembly": ["movz x0, #0x5ea7", "hvc #0"],
      "guestCodeAddress": hex(codeAddress), "codeBytes": codeSize,
      "entryCPSR": hex(entryCPSR), "entrySentinelX0": hex(entrySentinel),
      "markerX0": hex(marker), "expectedExitPC": hex(expectedExitPC),
      "codeSetup": "RW load, sys_icache_invalidate, hv_vm_protect R+X before any vCPU exists, "
        + "host mach_vm_protect R, instruction word read-back",
    ]
  }

  static func trialJSON(_ outcome: TrialOutcome) -> [String: Any] {
    let state = outcome.snapshot
    func first(_ step: TrialChannel.Step) -> Int? {
      state.events.first { $0.step == step }?.sequence
    }
    var json: [String: Any] = [:]
    json["name"] = outcome.name
    json["preEntryKickRequested"] = outcome.kick
    json["valid"] = outcome.valid
    json["invalidReasons"] = outcome.invalid
    json["processRetirementReason"] = orNull(outcome.retire)
    json["parentError"] = outcome.parentError
    json["vmCreateCode"] = number(outcome.vmCreateCode)
    json["vmDestroyedByApi"] = outcome.vmCreated && !outcome.vmRemains
    json["vcpuCreateCode"] = number(state.createCode)
    json["vcpuIdentifier"] = orNull(state.vcpu.map(hex))
    json["setupFailure"] = state.setupFailure
    json["entryReadbacks"] = state.readbacks.map {
      ["register": $0.register, "expected": hex($0.expected), "observed": hex($0.observed)]
    }
    json["parentHvVcpusExitIssued"] = state.kickCode != nil
    json["parentHvVcpusExitCode"] = number(state.kickCode)
    json["workerGate"] = state.gate.rawValue
    var ordering: [String: Any] = [:]
    ordering["publishedSequence"] = orNull(first(.published))
    ordering["kickBeginSequence"] = orNull(first(.kickBegin))
    ordering["kickReturnedSequence"] = orNull(first(.kickReturned))
    ordering["gateReleaseSequence"] = orNull(first(.gateRelease))
    ordering["gatePassedSequence"] = orNull(first(.gatePassed))
    ordering["firstRunBeginSequence"] = orNull(first(.runBegin))
    if let kick = first(.kickReturned), let release = first(.gateRelease) {
      ordering["kickReturnedBeforeGateRelease"] = kick < release
    }
    if let kick = first(.kickReturned), let begin = first(.runBegin) {
      ordering["kickReturnedBeforeFirstRunBegin"] = kick < begin
    }
    json["ordering"] = ordering
    json["runs"] = state.runs.map(runJSON)
    json["vcpuDestroyCode"] = number(state.destroyCode)
    json["pthreadJoinCode"] = number(state.joinCode)
    json["cleanupErrors"] = outcome.cleanupErrors
    json["events"] = state.events.map(eventJSON)
    return json
  }

  // The finding needs a valid no-kick control and a valid kick trial. A first run that executed
  // the guest is a finding too (no latching), never a reason to weaken any observation.
  static func verdict(_ outcomes: [TrialOutcome]) -> Verdict {
    var verdict = Verdict()
    guard outcomes.count == 2 else {
      verdict.summary = "indeterminate: the pre-entry-kick trial did not run"
      return verdict
    }
    guard outcomes[0].valid, outcomes[0].firstRun == .guestHVC else {
      verdict.summary = "indeterminate: the no-kick positive control did not validate"
      return verdict
    }
    guard outcomes[1].valid, let first = outcomes[1].firstRun else {
      verdict.summary = "indeterminate: the pre-entry-kick trial did not validate"
      return verdict
    }
    verdict.determinate = true
    if first == .canceledBeforeGuest {
      verdict.latched = true
      verdict.summary =
        "latched: the first hv_vcpu_run after a completed pre-entry hv_vcpus_exit returned "
        + "HV_EXIT_REASON_CANCELED with PC and X0 unchanged, before any guest instruction; a "
        + "follow-on run then reached the guest HVC marker. One single-vCPU trial only."
    } else {
      verdict.latched = false
      verdict.summary =
        "not latched: the first hv_vcpu_run after a completed pre-entry hv_vcpus_exit executed "
        + "the guest to the HVC marker, so the first entry was not cancelled. This trial does "
        + "not show whether the kick is retained for any later entry."
    }
    return verdict
  }

  // Exit status: 0 for a determinate finding with valid controls and cleanup (including a
  // not-latched finding), 1 for anything else, 2 after native process retirement.
  static func run(output path: String) throws {
    let file = try EvidenceFile.reserve(path)
    let deadline = DispatchTime.now() + .seconds(deadlineSeconds)
    var outcomes = [runTrial(name: "no-pre-entry-kick-control", kick: false, deadline: deadline)]
    var skipped = ""
    if outcomes[0].retire != nil || outcomes[0].vmRemains {
      skipped = "first trial left a VM or an unverified native thread"
    } else if DispatchTime.now() >= deadline {
      skipped = "host deadline reached before the second trial"
    } else {
      outcomes.append(runTrial(name: "pre-entry-kick", kick: true, deadline: deadline))
    }
    let result = verdict(outcomes)
    let retired = outcomes.compactMap(\.retire).first
    let probeFirstRun = outcomes.count == 2 ? outcomes[1].firstRun?.rawValue : nil
    let finding: [String: Any] = [
      "determinate": result.determinate,
      "preEntryCancellationLatched": orNull(result.latched),
      "firstRunAfterPreEntryKick": orNull(probeFirstRun),
      "summary": result.summary,
    ]
    var json: [String: Any] = [:]
    json["mode"] = "preentry-wake"
    json["schema"] = 1
    json["scope"] =
      "one-vCPU Hypervisor.framework pre-entry hv_vcpus_exit experiment on a synthetic EL1 "
      + "guest; not active-WFI, SMP, concurrent teardown, IO wake, 4-vCPU idle savings or "
      + "production readiness"
    json["hostDeadlineSeconds"] = deadlineSeconds
    json["hostDeadlineExpired"] = DispatchTime.now() >= deadline
    json["fixture"] = fixtureJSON()
    json["trials"] = outcomes.map(trialJSON)
    json["secondTrialSkippedReason"] = skipped
    json["finding"] = finding
    json["processRetired"] = retired != nil
    json["notExecuted"] = [
      "hv_vcpus_exit against a vCPU that is inside hv_vcpu_run",
      "WFI, guest timer, interrupt or IO wake",
      "SMP: exactly one vCPU per trial",
      "concurrent VM or vCPU teardown",
      "Linux kernel, initramfs, root disk or Apple Container",
      "idle-savings or CPU-time measurement",
      "adoption or removal of the production 2ms CPUGroup cadence",
    ]
    let data = try JSONSerialization.data(
      withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    if let retired {
      // A worker could not be proven finished: keep the evidence, never unmap under a CPU that
      // may still run, and let process exit retire the native objects.
      do { try file.finish(data) } catch { print("HVF_PREENTRY_EVIDENCE_FAIL \(error)") }
      print("HVF_PREENTRY_RETIRE \(retired)")
      fflush(nil)
      _exit(2)
    }
    try file.finish(data)
    guard result.determinate, let latched = result.latched else {
      throw Failure.experiment(result.summary)
    }
    print("HVF_PREENTRY_WAKE_COMPLETE latched=\(latched)")
  }
}

@main private struct Lab {
  static func main() {
    do { try run() } catch {
      print("HVF_LAB_FAIL \(error)")
      exit(1)
    }
  }

  private static func run() throws {
    let arguments = CommandLine.arguments
    // Early mode: no guest image is read and no Linux guest starts; existing modes are unchanged.
    if arguments.count == 3, arguments[1] == "preentry-wake" {
      try PreEntryWake.run(output: arguments[2])
      return
    }
    // Private Mach page-object experiment. The profile is validated before the result path is
    // reserved, so a malformed command line creates no file and touches no VM.
    if arguments.count == 4, arguments[1] == "mach-page-objects" {
      guard let profile = MachPageProfile(rawValue: arguments[3]) else { throw Failure.arguments }
      try MachPageObjects.run(output: arguments[2], profile: profile)
      return
    }
    guard arguments.count == 4,
      [
        "release", "held", "corrupt", "alias", "advice-dontneed", "advice-free",
        "advice-reusable", "cold-remap",
      ]
        .contains(arguments[3])
    else {
      throw Failure.arguments
    }
    let file = try FileHandle(forReadingFrom: URL(filePath: arguments[1]))
    let image: Data
    do {
      image = try file.read(upToCount: 65537) ?? Data()
      try file.close()
    } catch {
      try? file.close()
      throw error
    }
    guard !image.isEmpty, image.count <= 65536 else { throw Failure.arguments }
    let destination = URL(filePath: arguments[2])
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw Failure.arguments
    }
    let mode = arguments[3]
    let vm = Machine()
    var primary = ""
    var samples: [[String: Any]] = []
    var cycles = 0
    var releaseObservations: [UInt64] = []
    var adviceObservations: [[String: Any]] = []
    do {
      try check(hv_vm_create(nil), "create")
      vm.created = true
      let code = try vm.allocate(address: 0x100000, size: 65536)
      image.withUnsafeBytes {
        code.pointer!.copyMemory(from: $0.baseAddress!, byteCount: image.count)
      }
      sys_icache_invalidate(code.pointer!, image.count)
      try check(
        hv_vm_protect(
          code.address, code.size,
          UInt64(HV_MEMORY_READ | HV_MEMORY_EXEC)), "protect-code-rx")
      try check(
        mach_vm_protect(
          mach_task_self_, UInt64(UInt(bitPattern: code.pointer!)),
          UInt64(code.size), 0, VM_PROT_READ), "protect-code-host-ro")
      _ = try vm.allocate(address: 0x210000, size: 65536)
      let canary = try vm.allocate(address: 0x300000, size: 65536)
      var cpu: hv_vcpu_t = 0
      try check(hv_vcpu_create(&cpu, &vm.exitInfo, nil), "vcpu-create")
      vm.cpu = cpu
      try check(hv_vcpu_set_vtimer_mask(cpu, true), "mask-timer")
      try vm.execute(data: code, operation: 1, salt: 1, fault: .permission)
      let canarySalt: UInt64 = 0x5a5a_5a5a_0000_0000
      try vm.execute(data: canary, operation: 1, salt: canarySalt)
      let size = 64 << 20
      func sample(_ stage: String, _ data: Region) throws {
        let process = try ProcessMemorySnapshot.capture()
        samples.append([
          "stage": stage, "residentOwnedBytes": try vm.resident(data),
          "processResidentBytes": process.residentBytes,
          "physicalFootprintBytes": process.physicalFootprintBytes as Any,
          "backingObjectReferences": try vm.backingInfo(data).ref_count,
        ])
      }
      var held: Region?
      var coldReplacement: Region?
      func hostFreePages() throws -> UInt64 {
        var info = vm_statistics64_data_t()
        let capacity = MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(capacity)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
          pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
          }
        }
        try check(result, "host-vm-statistics")
        guard count == capacity else { throw Failure.observation }
        return UInt64(info.free_count)
      }
      for cycle in 0..<4 {
        guard let cycleStart = try ProcessMemorySnapshot.capture().physicalFootprintBytes
        else { throw Failure.observation }
        let data: Region
        if let replacement = coldReplacement {
          data = replacement
          coldReplacement = nil
        } else if let held {
          try vm.remap(held)
          data = held
        } else {
          data = try vm.allocate(address: 0x4000_0000, size: size)
        }
        if mode.hasPrefix("advice-") || mode == "cold-remap" {
          try sample("mapped-untouched-\(cycle)", data)
          guard try vm.resident(data) == 0 else { throw Failure.observation }
        }
        let salt = UInt64(0x1234_5678_0000_0000) + UInt64(cycle)
        try vm.execute(
          data: data, operation: cycle == 0 || mode != "held" ? 0 : 2,
          salt: cycle == 0 || mode != "held" ? salt : salt - 1)
        try vm.execute(data: data, operation: 1, salt: salt)
        if mode == "corrupt" {
          data.pointer!.storeBytes(of: UInt64(0), as: UInt64.self)
        }
        try vm.execute(data: data, operation: 2, salt: salt)
        try sample("written-\(cycle)", data)
        guard try vm.resident(data) == UInt64(size) else { throw Failure.observation }
        if mode.hasPrefix("advice-"), let pointer = data.pointer {
          let advice = mode == "advice-dontneed" ? MADV_DONTNEED
            : mode == "advice-free" ? MADV_FREE : MADV_FREE_REUSABLE
          let before = try ProcessMemorySnapshot.capture()
          let freeBefore = try hostFreePages()
          let status = madvise(pointer, size, advice)
          let error = status == 0 ? 0 : errno
          let after = try ProcessMemorySnapshot.capture()
          adviceObservations.append([
            "cycle": cycle, "nativeAdvice": advice, "nativeStatus": status, "errno": error,
            "residentOwnedAfterAdviceBytes": try vm.resident(data),
            "footprintBeforeBytes": before.physicalFootprintBytes as Any,
            "footprintAfterAdviceBytes": after.physicalFootprintBytes as Any,
            "hostFreePagesBefore": freeBefore, "hostFreePagesAfter": try hostFreePages(),
          ])
          if status == 0, advice == MADV_FREE_REUSABLE {
            guard madvise(pointer, size, MADV_FREE_REUSE) == 0 else {
              throw Failure.native("madvise-reuse", errno)
            }
          }
          // Never treat advice success as reclamation; prove both access views still agree.
          try vm.execute(data: data, operation: 1, salt: salt)
          try vm.execute(data: data, operation: 2, salt: salt)
          let words = pointer.assumingMemoryBound(to: UInt64.self)
          for index in 0..<(size / 8) {
            guard words[index] == salt ^ UInt64(index) else { throw Failure.mismatch }
          }
          words[0] = salt ^ 1
          do {
            try vm.execute(data: data, operation: 2, salt: salt)
            throw Failure.mismatch
          } catch Failure.guestResult(3) {}
          words[0] = salt
          try vm.execute(data: data, operation: 2, salt: salt)
          try vm.execute(data: canary, operation: 2, salt: canarySalt)
          guard try vm.resident(data) == UInt64(size) else { throw Failure.observation }
        }
        // A mapped, quiescent extent must never be freed while a stage-2 alias exists.
        do {
          try vm.release(data)
          throw Failure.mismatch
        } catch Failure.state {}
        try vm.unmap(data)
        try sample("unmapped-\(cycle)", data)
        guard try vm.resident(data) == UInt64(size) else { throw Failure.observation }
        if mode != "cold-remap" {
          for offset in stride(from: UInt64(0), to: UInt64(size), by: vm.pageSize) {
            try vm.execute(data: data, operation: 0, salt: salt, fault: .translation, offset: offset)
          }
        }
        if mode == "alias" {
          try vm.makeAlias(data)
          try sample("aliased-\(cycle)", data)
          do {
            try vm.release(data)
            throw Failure.mismatch
          } catch Failure.aliased(let count) {
            guard count >= 2 else { throw Failure.observation }
          }
          try vm.dropAlias()
        }
        if mode == "held" {
          try sample("held-unmapped-\(cycle)", data)
          try vm.execute(data: canary, operation: 2, salt: canarySalt)
          guard try vm.resident(canary) == UInt64(canary.size) else { throw Failure.observation }
          held = data
          cycles += 1
          continue
        }
        guard let before = try ProcessMemorySnapshot.capture().physicalFootprintBytes,
          let pointer = data.pointer
        else { throw Failure.observation }
        let oldAddress = UInt64(UInt(bitPattern: pointer))
        try vm.release(data)
        try vm.requireAbsent(address: oldAddress, size: size)
        let process = try ProcessMemorySnapshot.capture()
        guard let after = process.physicalFootprintBytes, before >= after,
          before - after >= UInt64(size), before - after - UInt64(size) <= 65536,
          cycle == 0 || (after > cycleStart ? after - cycleStart : cycleStart - after) <= 65536
        else { throw Failure.observation }
        releaseObservations.append(before - after)
        samples.append([
          "stage": "deallocated-\(cycle)",
          "processResidentBytes": process.residentBytes,
          "physicalFootprintBytes": process.physicalFootprintBytes as Any,
        ])
        if mode == "cold-remap", cycle < 3 {
          let replacement = try vm.allocate(address: data.address, size: size)
          try sample("cold-replacement-before-resume-\(cycle)", replacement)
          guard try vm.resident(replacement) == 0,
            let remapped = try ProcessMemorySnapshot.capture().physicalFootprintBytes,
            remapped <= after + 65536
          else { throw Failure.observation }
          coldReplacement = replacement
        }
        try vm.execute(data: canary, operation: 2, salt: canarySalt)
        guard try vm.resident(canary) == UInt64(canary.size) else { throw Failure.observation }
        cycles += 1
      }
    } catch { primary = String(describing: error) }
    let cleanup = vm.close()
    let result: [String: Any] = [
      "mode": mode, "cycles": cycles, "samples": samples,
      "primaryError": primary, "cleanupErrors": cleanup, "vmDestroyed": !vm.created,
      "scope": "owned HVF synthetic EL1 guest; not Apple Container or Linux balloon",
      "physicalReleasedBytes": NSNull(),
      "completedDeallocations": releaseObservations.count,
      "footprintReductionBytesPerCycle": releaseObservations,
      "hostFreeListDelta": NSNull(),
      "adviceObservations": adviceObservations,
      "mappedAdviceBackendQualified": false,
    ]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      .write(to: destination, options: .withoutOverwriting)
    guard primary.isEmpty, cleanup.isEmpty, cycles == 4, !vm.created else {
      throw Failure.mismatch
    }
    print("HVF_NATIVE_PASS \(mode) \(cycles)")
  }
}
