import BoundedMemory
import ContainerWorkspaceCore
import Darwin
import Foundation
import NativeLinuxVMM
import Synchronization

/// One caller-owned task. No stored Task can keep the governor alive after its owner exits.
final class ContinuousMemoryGovernor: Sendable {
  struct State: Sendable {
    var claimed = false
    var running = false
    var stop = false
    var pending = false
    var capacityReady = false
    var failure = ""
    var activeRequest: [String: UInt64] = [:]
    var sampleHistory = RecentHistory<[String: UInt64]>(capacity: 512)
    var requestHistory = RecentHistory<[String: UInt64]>(capacity: 32)
    var samples: [[String: UInt64]] { sampleHistory.elements }
    var requests: [[String: UInt64]] { requestHistory.elements }
  }
  private let state = Mutex(State())
  private let probe: MemoryProbeSession
  private let vm: NativeVirtualMachine
  private let bootGuestBytes: UInt64
  private let began: ContinuousClock.Instant
  private let lifetimeDeadline: ContinuousClock.Instant?
  private let samplingInterval: Duration
  var snapshot: State { state.withLock { $0 } }
  var status: (
    running: Bool, pending: Bool, failure: String, sampleCount: Int, capacityReady: Bool
  ) {
    state.withLock {
      ($0.running, $0.pending, $0.failure, Int(clamping: $0.sampleHistory.totalCount), $0.capacityReady)
    }
  }
  init(
    probe: MemoryProbeSession, vm: NativeVirtualMachine, began: ContinuousClock.Instant,
    bootGuestBytes: UInt64, lifetimeDeadline: ContinuousClock.Instant? = nil,
    samplingInterval: Duration = .milliseconds(200)
  ) {
    self.probe = probe
    self.vm = vm
    self.began = began
    self.bootGuestBytes = bootGuestBytes
    precondition(began <= .now && bootGuestBytes <= UInt64.max - (128 << 20))
    precondition(samplingInterval >= .milliseconds(100) && samplingInterval <= .seconds(1))
    self.lifetimeDeadline = lifetimeDeadline
    self.samplingInterval = samplingInterval
  }
  func requestStop() { state.withLock { $0.stop = true } }
  private var now: UInt64 {
    let d = began.duration(to: .now).components
    return UInt64(d.seconds) * 1_000_000_000 + UInt64(d.attoseconds / 1_000_000_000)
  }
  func run() async throws {
    try state.withLock {
      guard !$0.claimed else { throw LabFailure.invariant }
      $0.claimed = true
      $0.running = true
    }
    guard let budget = BalloonBudget(
      installedBytes: 1152 << 20, minimumResidentBytes: 1024 << 20,
      granuleBytes: 2 << 20, maximumStepBytes: 128 << 20),
      var controller = BalloonController(
        budget: budget, epoch: 1, guestReserveBytes: 512 << 20, hysteresisBytes: 32 << 20,
        maximumObservationAgeNanoseconds: 3_000_000_000, cooldownNanoseconds: 500_000_000,
        completionTimeoutNanoseconds: 8_000_000_000)
    else {
      state.withLock {
        $0.running = false
        $0.failure = "geometry"
      }
      throw LabFailure.invariant
    }
    var geometryDeadline: UInt64?
    defer {
      controller.retire()
      state.withLock { $0.running = false }
    }
    do {
      while true {
        try Task.checkCancellation()
        if state.withLock({ $0.stop }), controller.pendingRequest == nil, geometryDeadline == nil {
          return
        }
        if let lifetimeDeadline, ContinuousClock.now >= lifetimeDeadline {
          throw LabFailure.deadline
        }
        guard state.withLock({ $0.sampleHistory.remainingCounterValues > 0 }) else {
          throw LabFailure.invariant
        }
        try controller.checkDeadline(nowNanoseconds: now)
        if let geometryDeadline, now >= geometryDeadline {
          throw BalloonController.Failure.completionTimedOut
        }
        var deadline = ContinuousClock.now.advanced(by: .seconds(3))
        if let lifetimeDeadline { deadline = min(deadline, lifetimeDeadline) }
        if let pending = controller.pendingRequest {
          deadline = min(
            deadline, began.advanced(
              by: .nanoseconds(Int64(pending.issuedAtNanoseconds + 8_000_000_000))))
        }
        if let geometryDeadline {
          deadline = min(deadline, began.advanced(by: .nanoseconds(Int64(geometryDeadline))))
        }
        // Do not put an ambiguous command on the shared wire just as a fence expires.
        if deadline < ContinuousClock.now.advanced(by: .milliseconds(50)) {
          try await Task.sleep(until: deadline, clock: .continuous)
          continue
        }
        guard let reply = try await probe.observeIfIdle(deadline: deadline) else {
          try await Task.sleep(
            until: min(.now.advanced(by: samplingInterval), deadline), clock: .continuous)
          continue
        }
        try Task.checkCancellation()
        var pressure: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0) == 0,
          size == MemoryLayout<Int32>.size, [1, 2, 4].contains(pressure)
        else { throw LabFailure.invariant }
        let device = vm.memoryState
        try Task.checkCancellation()
        let returnedAt = now
        if let lifetimeDeadline, ContinuousClock.now >= lifetimeDeadline {
          throw LabFailure.deadline
        }
        try controller.checkDeadline(nowNanoseconds: returnedAt)
        if let geometryDeadline, returnedAt >= geometryDeadline {
          throw BalloonController.Failure.completionTimedOut
        }
        guard returnedAt >= reply.capturedAt,
          returnedAt - reply.capturedAt <= 3_000_000_000,
          reply.total >= bootGuestBytes, reply.total <= bootGuestBytes + (128 << 20),
          device.pluggedBytes <= 128 << 20, device.requestedBytes <= 128 << 20
        else { throw LabFailure.invariant }
        let capacityReady = reply.total == bootGuestBytes + device.pluggedBytes
        if capacityReady, controller.pendingRequest == nil { geometryDeadline = nil }
        else if !capacityReady, geometryDeadline == nil {
          geometryDeadline = returnedAt + 8_000_000_000
        }
        let sample = BalloonController.Observation(
          epoch: 1, sequence: reply.sequence, capturedAtNanoseconds: reply.capturedAt,
          actualResidentBytes: (1024 << 20) + device.pluggedBytes,
          requestedResidentBytes: (1024 << 20) + device.requestedBytes,
          guestAvailableBytes: reply.available, hostResidentLimitBytes: 1152 << 20,
          hostUnderPressure: pressure != 1, guestUnderPressure: false)
        // No suspension between policy admission, native setter and delivery fence.
        // Native mapping completion can precede Linux memory-online accounting.
        // Stop and new admissions share one linearization point; no lock crosses an await.
        try state.withLock { snapshot in
          let request: BalloonController.Request?
          let lifetimeAdmits = lifetimeDeadline.map {
            ContinuousClock.now.advanced(by: .seconds(8)) <= $0
          } ?? true
          if (snapshot.stop || !lifetimeAdmits), controller.pendingRequest == nil,
            geometryDeadline == nil { request = nil }
          // Pending rescue remains enabled while Linux online accounting lags.
          else if capacityReady || controller.pendingRequest != nil || reply.available < 512 << 20 {
            request = try controller.observe(sample, nowNanoseconds: returnedAt)
          } else { request = nil }
          if let request {
            guard snapshot.requestHistory.remainingCounterValues > 0 else {
              throw LabFailure.invariant
            }
            snapshot.pending = true
            snapshot.activeRequest = [
              "initialBytes": request.initialResidentBytes,
              "targetBytes": request.targetResidentBytes, "sequence": request.sequence,
              "issuedAt": request.issuedAtNanoseconds,
            ]
            geometryDeadline = request.issuedAtNanoseconds + 8_000_000_000
            try vm.requestMemory(bytes: request.targetResidentBytes - (1024 << 20))
            let deliveredAt = now
            snapshot.activeRequest["deliveredAt"] = deliveredAt
            try snapshot.requestHistory.append([
              "initialBytes": request.initialResidentBytes,
              "targetBytes": request.targetResidentBytes,
              "sequence": request.sequence, "issuedAt": request.issuedAtNanoseconds,
              "deliveredAt": deliveredAt,
            ])
            try controller.didApply(
              request, afterObservationSequence: reply.sequence, atNanoseconds: deliveredAt)
          }
          if capacityReady, controller.pendingRequest == nil { geometryDeadline = nil }
          let pending = controller.pendingRequest != nil || geometryDeadline != nil
          snapshot.pending = pending
          if !pending { snapshot.activeRequest = [:] }
          snapshot.capacityReady = capacityReady
          try snapshot.sampleHistory.append([
            "sequence": reply.sequence, "capturedAt": reply.capturedAt, "returnedAt": returnedAt,
            "guestAvailableBytes": reply.available, "guestTotalBytes": reply.total,
            "pluggedBytes": device.pluggedBytes, "requestedBytes": device.requestedBytes,
            "hostPressure": UInt64(pressure), "pending": pending ? 1 : 0,
            "guestCapacityReady": capacityReady ? 1 : 0,
          ])
        }
        var wake = ContinuousClock.now.advanced(by: samplingInterval)
        if let lifetimeDeadline { wake = min(wake, lifetimeDeadline) }
        if let geometryDeadline {
          wake = min(wake, began.advanced(by: .nanoseconds(Int64(geometryDeadline))))
        }
        try await Task.sleep(until: wake, clock: .continuous)
      }
    } catch {
      state.withLock {
        $0.failure = String(describing: error)
        $0.running = false
      }
      throw error
    }
  }
}
