import Darwin
import Dispatch
import Foundation
import Hypervisor
import Synchronization

struct CPURegisters: Sendable {
  var values = InlineArray<33, UInt64>(repeating: 0)
  var dirty: UInt64 = 0
  var available: UInt64 = 0
  static func index(_ register: hv_reg_t) throws -> Int {
    if register == HV_REG_PC { return 31 }
    if register == HV_REG_CPSR { return 32 }
    guard register.rawValue < 31 else { throw Failure.boundary }
    return Int(register.rawValue)
  }
  static func register(_ index: Int) -> hv_reg_t {
    index == 31 ? HV_REG_PC : index == 32 ? HV_REG_CPSR : hv_reg_t(rawValue: UInt32(index))
  }
  mutating func set(_ register: hv_reg_t, _ value: UInt64) throws {
    let index = try Self.index(register)
    values[index] = value
    available |= 1 << index
    dirty |= 1 << index
  }
}

struct CPUExit: Sendable {
  var reason: UInt32 = 0
  var syndrome: UInt64 = 0
  var physicalAddress: UInt64 = 0
  var registers = CPURegisters()
}

private final class CPUKickTarget: Sendable {
  let state = Mutex<(workers: [NativeCPUWorker], error: Int32)>(([], 0))
}

private final class FirstReturn: Sendable {
  let returned = Mutex(false)
  let signal = DispatchSemaphore(value: 0)
  func reset() { returned.withLock { $0 = false } }
  func notify() {
    let first = returned.withLock { value in
      let first = !value
      value = true
      return first
    }
    if first { signal.signal() }
  }
}

private final class NativeCPUWorker: Sendable {
  struct State {
    var powered = false
    var parked = true
    var stop = false
    var ended = false
    var nativeID: hv_vcpu_t?
    var worker: UInt = 0
    var joined = false
    var error = ""
    var destroyError: Int32 = 0
    var pending = CPURegisters()
    var result = CPUExit()
    var runs = 0
    var canceledRuns = 0
    var executionTicks: UInt64 = 0
  }
  let state = Mutex(State())
  let wake = DispatchSemaphore(value: 0)
  let ready = DispatchSemaphore(value: 0)
  let done = DispatchSemaphore(value: 0)
  let ended = DispatchSemaphore(value: 0)
  let index: Int
  let returned: FirstReturn
  init(index: Int, returned: FirstReturn) {
    self.index = index
    self.returned = returned
  }
  func start() throws {
    try state.withLock { state in
      let context = Unmanaged.passRetained(self).toOpaque()
      var thread: pthread_t?
      let result = pthread_create(
        &thread, nil,
        { context in
          Unmanaged<NativeCPUWorker>.fromOpaque(context).takeRetainedValue().run()
          return nil
        }, context)
      guard result == 0 else {
        Unmanaged<NativeCPUWorker>.fromOpaque(context).release()
        throw Failure.native("pthread-create-vcpu", result)
      }
      state.worker = UInt(bitPattern: thread!)
    }
    guard ready.wait(timeout: .now() + 5) == .success else { throw Failure.deadline }
    let error = state.withLock { $0.error }
    guard error.isEmpty else { throw NativeFailure.stopped(error) }
  }
  private func run() {
    var cpu: hv_vcpu_t = 0
    var exit: UnsafeMutablePointer<hv_vcpu_exit_t>?
    var created = false
    do {
      try check(hv_vcpu_create(&cpu, &exit, nil), "cpu-create")
      created = true
      try check(hv_vcpu_set_sys_reg(cpu, HV_SYS_REG_SCTLR_EL1, 0x00c5_0838), "sctlr")
      try check(hv_vcpu_set_sys_reg(cpu, HV_SYS_REG_MPIDR_EL1, UInt64(index)), "mpidr")
      try check(hv_vcpu_set_vtimer_mask(cpu, true), "mask-unused-virtual-timer")
      state.withLock { $0.nativeID = cpu }
    } catch { state.withLock { $0.error = String(describing: error) } }
    ready.signal()
    if state.withLock({ $0.error.isEmpty }) {
      while true {
        wake.wait()
        let command = state.withLock { ($0.stop, $0.pending) }
        if command.0 { break }
        do {
          for i in 0..<33 where command.1.dirty & (1 << i) != 0 {
            try check(
              hv_vcpu_set_reg(cpu, CPURegisters.register(i), command.1.values[i]), "cpu-set")
          }
          try check(hv_vcpu_run(cpu), "cpu-run")
          guard let exit else { throw Failure.boundary }
          var result = CPUExit(
            reason: exit.pointee.reason.rawValue,
            syndrome: exit.pointee.exception.syndrome,
            physicalAddress: exit.pointee.exception.physical_address)
          // Read only registers consumed by this exit; other architectural state stays in HVF.
          var selected: UInt64 = 1 << 31
          if result.reason == HV_EXIT_REASON_EXCEPTION.rawValue {
            switch result.syndrome >> 26 {
            case 0x16: selected |= 15
            case 0x18:
              let rt = (result.syndrome >> 5) & 31
              if rt != 31 { selected |= 1 << rt }
            case 0x24:
              let rt = (result.syndrome >> 16) & 31
              if rt != 31 { selected |= 1 << rt }
            default: break
            }
          }
          for i in 0..<33 where selected & (1 << i) != 0 {
            var value: UInt64 = 0
            try check(hv_vcpu_get_reg(cpu, CPURegisters.register(i), &value), "cpu-get")
            result.registers.values[i] = value
          }
          result.registers.available = selected
          state.withLock {
            $0.result = result
            $0.pending = result.registers
            $0.runs += 1
            if result.reason == HV_EXIT_REASON_CANCELED.rawValue { $0.canceledRuns += 1 }
          }
        } catch { state.withLock { $0.error = String(describing: error) } }
        state.withLock { $0.parked = true }
        returned.notify()
        done.signal()
      }
    }
    if created {
      var ticks: UInt64 = 0
      let timeResult = hv_vcpu_get_exec_time(cpu, &ticks)
      state.withLock {
        $0.executionTicks = ticks
        if timeResult != 0 { $0.error += " execution-time \(timeResult)" }
      }
      let result = hv_vcpu_destroy(cpu)
      state.withLock {
        $0.destroyError = result
        if result == 0 { $0.nativeID = nil }
      }
    }
    state.withLock { $0.ended = true }
    ended.signal()
  }
  func stopAndJoin() throws {
    if state.withLock({ $0.joined }) { return }
    let worker = state.withLock { state -> UInt in
      state.stop = true
      return state.worker
    }
    guard worker != 0 else { return }
    wake.signal()
    guard ended.wait(timeout: .now() + 5) == .success else { throw Failure.deadline }
    let result = pthread_join(pthread_t(bitPattern: worker)!, nil)
    state.withLock { $0.joined = result == 0 }
    try check(result, "pthread-join-vcpu")
    try check(state.withLock { $0.destroyError }, "cpu-destroy")
  }
}

/// Native workers exchange register values; guest RAM remains coordinator-confined.
final class CPUGroup {
  private let first = FirstReturn()
  private var workers: [NativeCPUWorker] = []
  private let kick = CPUKickTarget()
  private var closed = false
  private var poisoned = false
  private let timerQueue = DispatchQueue(label: "NativeLinuxVMM.vcpu-exit")
  private var timer: DispatchSourceTimer?
  private(set) var epoch = 0
  private(set) var maximumScheduled = 0
  var isQuiescent: Bool { workers.allSatisfy { $0.state.withLock { $0.parked } } }
  var count: Int { workers.count }
  var statistics: [[String: Any]] {
    workers.map { worker in
      worker.state.withLock {
        [
          "index": worker.index, "runs": $0.runs, "joined": $0.joined,
          "canceledRuns": $0.canceledRuns, "guestExecutionTicks": $0.executionTicks,
          "nativeDestroyed": $0.nativeID == nil, "error": $0.error,
          "destroyError": $0.destroyError,
        ]
      }
    }
  }
  func create(count: Int) throws {
    guard (1...4).contains(count), workers.isEmpty else { throw Failure.arguments }
    for index in 0..<count {
      let worker = NativeCPUWorker(index: index, returned: first)
      workers.append(worker)
      try worker.start()
    }
    kick.state.withLock { $0.workers = workers }
    let target = kick
    let timer = DispatchSource.makeTimerSource(queue: timerQueue)
    timer.setEventHandler {
      target.state.withLock { target in
        var ids = target.workers.compactMap { worker in
          worker.state.withLock { $0.parked ? nil : $0.nativeID }
        }
        guard !ids.isEmpty else { return }
        let result = ids.withUnsafeMutableBufferPointer {
          hv_vcpus_exit($0.baseAddress!, UInt32($0.count))
        }
        if result != 0, target.error == 0 { target.error = result }
      }
    }
    timer.schedule(deadline: .now() + .milliseconds(2), repeating: .milliseconds(2))
    timer.resume()
    self.timer = timer
  }
  func activate(_ index: Int, pc: UInt64, context: UInt64) throws -> Bool {
    guard !closed, !poisoned, workers.indices.contains(index), isQuiescent else {
      throw Failure.boundary
    }
    return try workers[index].state.withLock {
      guard !$0.powered else { return false }
      $0.powered = true
      $0.pending = CPURegisters()
      $0.pending.dirty = (1 << 33) - 1
      try $0.pending.set(HV_REG_PC, pc)
      try $0.pending.set(HV_REG_X0, context)
      try $0.pending.set(HV_REG_CPSR, 0x3c5)
      return true
    }
  }
  func powered(_ index: Int) -> Bool {
    workers.indices.contains(index) && workers[index].state.withLock { $0.powered }
  }
  func update(_ index: Int, registers: CPURegisters) throws {
    guard !closed, !poisoned, workers.indices.contains(index), isQuiescent else {
      throw Failure.boundary
    }
    workers[index].state.withLock { $0.pending = registers }
  }
  private func requestExit() throws {
    try kick.state.withLock {
      try check($0.error, "watchdog-exit")
      var ids = $0.workers.compactMap { worker in
        worker.state.withLock { $0.parked ? nil : $0.nativeID }
      }
      if !ids.isEmpty {
        try check(
          ids.withUnsafeMutableBufferPointer {
            hv_vcpus_exit($0.baseAddress!, UInt32($0.count))
          }, "pause-vcpus")
      }
    }
  }
  func runEpoch() throws -> [(Int, CPUExit)] {
    guard !closed, !poisoned, isQuiescent else { throw Failure.boundary }
    var completed = false
    defer { if !completed { poisoned = true } }
    first.reset()
    let active = workers.indices.filter { powered($0) }
    guard !active.isEmpty else { throw Failure.protocolError }
    for index in active {
      let error = workers[index].state.withLock { $0.error }
      guard error.isEmpty else { throw NativeFailure.stopped(error) }
    }
    maximumScheduled = max(maximumScheduled, active.count)
    // Rotate the first wake: a fast MMIO CPU must not perpetually pre-cancel its peer.
    let turn = epoch % active.count
    let order = active.dropFirst(turn) + active.prefix(turn)
    for index in order {
      workers[index].state.withLock { $0.parked = false }
      workers[index].wake.signal()
    }
    guard first.signal.wait(timeout: .now() + 5) == .success else { throw Failure.deadline }
    try requestExit()
    let deadline = DispatchTime.now() + 5
    for index in active {
      guard workers[index].done.wait(timeout: deadline) == .success else { throw Failure.deadline }
    }
    guard isQuiescent else { throw Failure.boundary }
    epoch += 1
    let results = try active.map { index in
      try workers[index].state.withLock {
        guard $0.error.isEmpty else { throw NativeFailure.stopped($0.error) }
        return (index, $0.result)
      }
    }
    completed = true
    return results
  }
  func close() -> [String] {
    if closed { return [] }
    var failures: [String] = []
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !isQuiescent {
      do { try requestExit() } catch { return ["vcpu-pause \(error)"] }
      guard ContinuousClock.now < deadline else { return ["vcpu-pause deadline"] }
      usleep(1000)
    }
    kick.state.withLock { $0.workers.removeAll() }
    timer?.cancel()
    timerQueue.sync {}
    timer = nil
    for worker in workers {
      do { try worker.stopAndJoin() } catch { failures.append("vcpu-stop \(error)") }
    }
    closed = failures.isEmpty
    return failures
  }
}
