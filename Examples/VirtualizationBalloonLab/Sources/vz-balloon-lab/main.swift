import BoundedMemory
import CryptoKit
import Darwin
import Foundation
import PageMemory
import Virtualization

private enum Failure: Error {
  case arguments, framing, guest, deadline, noAcknowledgement, state, mismatch, disconnected
}
private struct Observation {
  let sequence: UInt64
  let capturedAtNanoseconds: UInt64
  let total: UInt64
  let available: UInt64
  let regionPages: UInt64
  let guestRSS: UInt64
  let requested: UInt32
  let actual: UInt32
}

@MainActor private final class Completion {
  var result: Result<Void, any Error>?
}

// A disposable CLI, confined to VZ's documented default main queue; no UI or worker actor.
@main @MainActor private struct Lab {
  static func main() async {
    do { try await run() } catch {
      print("VZ_LAB_FAIL \(error)")
      exit(1)
    }
  }

  private static func transition(_ vm: VZVirtualMachine, start: Bool) async throws {
    dispatchPrecondition(condition: .onQueue(.main))
    let completion = Completion()
    if start {
      vm.start { result in MainActor.assumeIsolated { completion.result = result } }
    } else {
      vm.stop { error in
        MainActor.assumeIsolated {
          completion.result = error.map { .failure($0) } ?? .success(())
        }
      }
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(start ? 15 : 5))
    while completion.result == nil {
      guard ContinuousClock.now < deadline else { throw Failure.deadline }
      try await Task.sleep(for: .milliseconds(10))
    }
    try completion.result!.get()
  }

  private static func run() async throws {
    let args = CommandLine.arguments
    guard args.count == 5,
      ["cycles", "absent", "ignored", "cancel-inflated", "policy"].contains(args[4]),
      VZVirtualMachine.isSupported
    else { throw Failure.arguments }
    let kernel = URL(filePath: args[1])
    let initramfs = URL(filePath: args[2])
    let root = URL(filePath: args[3]).standardizedFileURL
    let mode = args[4]
    let inputHashes = try [kernel, initramfs].map { url in
      SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
        .map { String(format: "%02x", $0) }.joined()
    }
    guard !FileManager.default.fileExists(atPath: root.path) else { throw Failure.arguments }
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let console = root.appending(path: "console.log")
    guard FileManager.default.createFile(atPath: console.path, contents: nil) else {
      throw Failure.arguments
    }
    let log = try FileHandle(forWritingTo: console)
    defer { try? log.close() }
    let input = Pipe()
    let output = Pipe()
    defer {
      try? input.fileHandleForReading.close()
      try? input.fileHandleForWriting.close()
      try? output.fileHandleForReading.close()
      try? output.fileHandleForWriting.close()
    }
    for fd in [
      input.fileHandleForWriting.fileDescriptor, output.fileHandleForReading.fileDescriptor,
    ] {
      let flags = fcntl(fd, F_GETFL)
      guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
        throw Failure.arguments
      }
    }
    _ = signal(SIGPIPE, SIG_IGN)
    let installed: UInt64 = 256 * 1024 * 1024
    let reduction: UInt64 = 128 * 1024 * 1024
    let config = VZVirtualMachineConfiguration()
    let boot = VZLinuxBootLoader(kernelURL: kernel)
    boot.initialRamdiskURL = initramfs
    boot.commandLine =
      "console=hvc0 rdinit=/init panic=0 quiet"
      + (mode == "ignored" ? " initcall_blacklist=virtio_balloon_driver_init" : "")
    config.bootLoader = boot
    config.cpuCount = 1
    config.memorySize = installed
    config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
    serial.attachment = VZFileHandleSerialPortAttachment(
      fileHandleForReading: input.fileHandleForReading,
      fileHandleForWriting: output.fileHandleForWriting)
    config.serialPorts = [serial]
    config.memoryBalloonDevices =
      mode == "absent" ? [] : [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
    guard config.networkDevices.isEmpty, config.storageDevices.isEmpty,
      config.directorySharingDevices.isEmpty, config.socketDevices.isEmpty
    else { throw Failure.arguments }
    try config.validate()
    let vm = VZVirtualMachine(configuration: config)
    var buffer = Data()
    var received = 0
    var sequence: UInt64 = 0
    var observations: [[String: Any]] = []
    var baseline: UInt64 = 0
    var pageSize: UInt64 = 0
    var guestDriverState = ""
    let began = ContinuousClock.now
    let deadline = began.advanced(by: .seconds(120))
    func line(boot: Bool = false) async throws -> String {
      let end = min(deadline, ContinuousClock.now.advanced(by: .seconds(boot ? 10 : 3)))
      while ContinuousClock.now < end {
        if let end = buffer.firstIndex(of: 10) {
          let bytes = buffer[..<end]
          guard bytes.count <= 8192, let text = String(data: bytes, encoding: .utf8) else {
            throw Failure.framing
          }
          buffer.removeSubrange(...end)
          if text.hasPrefix("PROBE_FAIL") { throw Failure.guest }
          if text.hasPrefix("PROBE_") { return text }
          continue
        }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = bytes.withUnsafeMutableBytes {
          read(output.fileHandleForReading.fileDescriptor, $0.baseAddress, $0.count)
        }
        if count > 0 {
          received += count
          guard received <= 1024 * 1024, buffer.count + count <= 16384 else {
            throw Failure.framing
          }
          let next = Data(bytes.prefix(count))
          try log.write(contentsOf: next)
          buffer.append(next)
        } else {
          guard count < 0, errno == EAGAIN || errno == EINTR else {
            throw Failure.disconnected
          }
          guard vm.state == .running || vm.state == .starting else { throw Failure.state }
          try await Task.sleep(for: .milliseconds(10))
        }
      }
      throw Failure.deadline
    }
    func elapsedNanoseconds() -> UInt64 {
      let elapsed = began.duration(to: .now).components
      return UInt64(elapsed.seconds) * 1_000_000_000
        + UInt64(elapsed.attoseconds / 1_000_000_000)
    }
    func observe(_ command: String, label: String) async throws -> Observation {
      let captureStart = elapsedNanoseconds()
      sequence += 1
      let request = Data("\(command) \(sequence)\n".utf8)
      let written = request.withUnsafeBytes {
        write(input.fileHandleForWriting.fileDescriptor, $0.baseAddress, $0.count)
      }
      // One short atomic pipe write; any failure retires the entire disposable VM.
      guard written == request.count else { throw Failure.disconnected }
      let words = try await line().split(separator: " ")
      guard words.count == 8, words[0] == "PROBE_OBS", UInt64(words[1]) == sequence,
        let total = UInt64(words[2]), total > 0, total <= installed,
        let available = UInt64(words[3]), available <= total,
        let pages = UInt64(words[4]), pages <= 64 * 1024 * 1024 / pageSize,
        let rss = UInt64(words[5]), rss <= installed,
        let requested = UInt32(words[6]), let actual = UInt32(words[7])
      else { throw Failure.framing }
      let host = try ProcessMemorySnapshot.capture()
      let elapsed = began.duration(to: .now).components
      let nanos =
        UInt64(elapsed.seconds) * 1_000_000_000 + UInt64(elapsed.attoseconds / 1_000_000_000)
      observations.append([
        "hostElapsedNanoseconds": nanos,
        "label": label, "sequence": sequence, "guestTotalBytes": total,
        "guestAvailableBytes": available, "guestRegionResidentPages": pages,
        "guestRSSBytes": rss, "balloonRequestedPages": requested, "balloonActualPages": actual,
        "hostControllerRSSBytes": host.residentBytes,
        "hostControllerFootprintBytes": host.physicalFootprintBytes.map { $0 as Any } ?? NSNull(),
      ])
      return Observation(
        sequence: sequence, capturedAtNanoseconds: captureStart,
        total: total, available: available, regionPages: pages, guestRSS: rss, requested: requested,
        actual: actual)
    }
    func waitBalloon(_ expected: UInt32, label: String, seconds: Int) async throws {
      let end = ContinuousClock.now.advanced(by: .seconds(seconds))
      while ContinuousClock.now < end {
        let current = try await observe("S", label: label)
        if current.requested == expected && current.actual == expected { return }
        try await Task.sleep(for: .milliseconds(100))
      }
      throw Failure.noAcknowledgement
    }
    var primary: (any Error)?
    var cleanup: (any Error)?
    var cycles = 0
    var policyRequests: [[String: Any]] = []
    do {
      try await transition(vm, start: true)
      let ready = try await line(boot: true).split(separator: " ")
      guard ready.count == 5, ready[0] == "PROBE_READY", let size = UInt64(ready[1]),
        size == 4096, let total = UInt64(ready[2]), total > reduction, total <= installed,
        let available = UInt64(ready[3]), available <= total
      else { throw Failure.framing }
      pageSize = size
      baseline = total
      guestDriverState = String(ready[4])
      switch mode {
      case "absent": guard guestDriverState == "none" else { throw Failure.mismatch }
      case "ignored": guard guestDriverState == "unbound" else { throw Failure.mismatch }
      default:
        guard guestDriverState.hasPrefix("bound:"), guestDriverState.count >= 70,
          guestDriverState.count <= 262,
          guestDriverState.dropFirst(6).allSatisfy({ $0 == "0" || $0 == "1" })
        else { throw Failure.framing }
      }
      if mode == "absent" {
        guard vm.memoryBalloonDevices.isEmpty else { throw Failure.mismatch }
        _ = try await observe("S", label: "absent")
      } else {
        guard vm.memoryBalloonDevices.count == 1,
          let balloon = vm.memoryBalloonDevices[0] as? VZVirtioTraditionalMemoryBalloonDevice
        else { throw Failure.mismatch }
        if mode == "policy" {
          let mib: UInt64 = 1 << 20
          guard VZVirtualMachineConfiguration.minimumAllowedMemorySize <= 192 * mib,
            let budget = BalloonBudget(
              installedBytes: installed, minimumResidentBytes: 192 * mib, granuleBytes: mib,
              maximumStepBytes: 32 * mib),
            var controller = BalloonController(
              budget: budget, epoch: 1, guestReserveBytes: 96 * mib, hysteresisBytes: 16 * mib,
              maximumObservationAgeNanoseconds: 3_000_000_000,
              cooldownNanoseconds: 100_000_000, completionTimeoutNanoseconds: 8_000_000_000)
          else { throw Failure.arguments }
          defer { controller.retire() }
          let warm = try await observe("T", label: "policy-warm")
          guard warm.regionPages == 64 * mib / pageSize else { throw Failure.mismatch }
          var grows = 0
          var shrinks = 0
          // One isolated VM/pipe namespace; epoch1 is never restored into another transport.
          for phase in 0..<3 {
            let region = try await observe(phase == 1 ? "T" : "E", label: "policy-phase-\(phase)")
            if phase != 1 && region.regionPages != 0 { throw Failure.mismatch }
            if phase == 0 && region.available < 160 * mib { throw Failure.mismatch }
            var settled = false
            var idleSamples = 0
            for _ in 0..<32 {
              try controller.checkDeadline(nowNanoseconds: elapsedNanoseconds())
              let current = try await observe("S", label: "policy-state-\(phase)")
              let actualBytes = UInt64(current.actual) * 4096
              let requestedBytes = UInt64(current.requested) * 4096
              guard actualBytes <= installed, requestedBytes <= installed else {
                throw Failure.mismatch
              }
              let allowance = installed - actualBytes
              let observation = BalloonController.Observation(
                epoch: 1, sequence: current.sequence,
                capturedAtNanoseconds: current.capturedAtNanoseconds,
                actualResidentBytes: allowance, requestedResidentBytes: installed - requestedBytes,
                guestAvailableBytes: current.available,
                hostResidentLimitBytes: installed,
                hostUnderPressure: false, guestUnderPressure: false)
              if let request = try controller.observe(
                observation, nowNanoseconds: elapsedNanoseconds())
              {
                guard vm.state == .running, request.targetResidentBytes % mib == 0,
                  request.targetResidentBytes >= budget.minimumResidentBytes,
                  request.targetResidentBytes <= installed
                else { throw Failure.state }
                if request.targetResidentBytes < allowance { shrinks += 1 } else { grows += 1 }
                balloon.targetVirtualMachineMemorySize = request.targetResidentBytes
                guard balloon.targetVirtualMachineMemorySize == request.targetResidentBytes else {
                  throw Failure.mismatch
                }
                try controller.didApply(
                  request, afterObservationSequence: sequence, atNanoseconds: elapsedNanoseconds())
                idleSamples = 0
                policyRequests.append([
                  "epoch": request.epoch, "sequence": request.sequence,
                  "initialResidentBytes": allowance,
                  "targetResidentBytes": request.targetResidentBytes,
                  "guestAvailableBytes": current.available,
                  "issuedAtNanoseconds": request.issuedAtNanoseconds,
                ])
              } else if controller.pendingRequest == nil {
                idleSamples += 1
                if idleSamples >= 2 {
                  settled = true
                  break
                }
              } else {
                idleSamples = 0
              }
              try await Task.sleep(for: .milliseconds(100))
            }
            guard settled, controller.pendingRequest == nil else { throw Failure.noAcknowledgement }
          }
          guard grows > 0, shrinks >= 2 else { throw Failure.mismatch }
          controller.retire()
          // Manual final restore follows policy retirement; it is not a policy decision.
          balloon.targetVirtualMachineMemorySize = installed
          try await waitBalloon(0, label: "policy-end-restore", seconds: 8)
          let reused = try await observe("T", label: "policy-final-reuse")
          guard reused.regionPages == 64 * mib / pageSize else { throw Failure.mismatch }
          _ = try await observe("E", label: "policy-final-erase")
          cycles = 1
        } else {
          for cycle in 0..<(mode == "cycles" ? 4 : 1) {
            let touched = try await observe("T", label: "touched-\(cycle)")
            guard touched.total == baseline, touched.regionPages == 64 * 1024 * 1024 / pageSize
            else { throw Failure.mismatch }
            let erased = try await observe("E", label: "erased-\(cycle)")
            guard erased.regionPages == 0, erased.available >= reduction + 32 * 1024 * 1024 else {
              throw Failure.mismatch
            }
            guard vm.state == .running else { throw Failure.state }
            balloon.targetVirtualMachineMemorySize = installed - reduction
            guard balloon.targetVirtualMachineMemorySize == installed - reduction else {
              throw Failure.mismatch
            }
            if mode == "ignored" {
              do {
                try await waitBalloon(UInt32(reduction / 4096), label: "ignored", seconds: 2)
                throw Failure.mismatch
              } catch Failure.noAcknowledgement {}
              let late = try await observe("S", label: "ignored-deadline")
              guard late.actual == 0, late.requested == UInt32(reduction / 4096) else {
                throw Failure.mismatch
              }
              break
            }
            try await waitBalloon(UInt32(reduction / 4096), label: "inflated-\(cycle)", seconds: 8)
            if mode == "cancel-inflated" {
              withUnsafeCurrentTask { $0?.cancel() }
              break
            }
            guard vm.state == .running else { throw Failure.state }
            balloon.targetVirtualMachineMemorySize = installed
            guard balloon.targetVirtualMachineMemorySize == installed else {
              throw Failure.mismatch
            }
            try await waitBalloon(0, label: "deflated-\(cycle)", seconds: 8)
            cycles += 1
          }
          if mode == "cycles" {
            let reused = try await observe("T", label: "final-reuse")
            guard reused.regionPages == 64 * 1024 * 1024 / pageSize else { throw Failure.mismatch }
            _ = try await observe("E", label: "final-erase")
          }
        }
      }
    } catch { primary = error }
    // An owned cleanup task is deliberately not cancelled with the calling task.
    let stop = Task { @MainActor in
      if vm.canStop { try await transition(vm, start: false) }
      guard vm.state == .stopped else { throw Failure.state }
    }
    do { try await stop.value } catch { cleanup = error }
    let result: [String: Any] = [
      "kernelSHA256": inputHashes[0], "initramfsSHA256": inputHashes[1],
      "commandLine": boot.commandLine, "guestBalloonDriverState": guestDriverState,
      "mode": mode, "cycles": cycles, "observations": observations,
      "policyRequests": policyRequests,
      "policyHostBudgetScope":
        "fixed owned VM ceiling; no host pressure induced or fleet reservation",

      "installedBytes": installed, "reductionRequestedBytes": reduction,
      "guestBaselineTotalBytes": baseline, "guestPageSize": pageSize,
      "stopped": vm.state == .stopped, "callerCancelled": Task.isCancelled,
      "networkDevices": config.networkDevices.count,
      "storageDevices": config.storageDevices.count, "physicalReleasedBytes": NSNull(),
      "hostCountersScope": "controller process only; VM service/backing attribution unproven",
      "primaryError": primary.map { String(describing: $0) } ?? "",
      "cleanupError": cleanup.map { String(describing: $0) } ?? "",
      "elapsed": String(describing: began.duration(to: .now)),
    ]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      .write(to: root.appending(path: "result.json"))
    if let primary { throw primary }
    if let cleanup { throw cleanup }
    print("VZ_LAB_PASS \(mode) \(cycles)")
  }
}
