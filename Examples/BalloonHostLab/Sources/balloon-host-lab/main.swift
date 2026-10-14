import BoundedMemory
import Foundation
import HostLab

#if canImport(Darwin)
  import Darwin
#elseif canImport(Musl)
  import Musl
#else
  import Glibc
#endif

private enum Failure: Error { case arguments, mismatch, cleanup }

// The lab owns exactly this child; QEMU is configured without disks, NICs or subprocess backends.
private func stop(_ process: Process) throws {
  if process.isRunning {
    process.terminate()
    let end = ContinuousClock.now.advanced(by: .seconds(2))
    while process.isRunning && ContinuousClock.now < end { Thread.sleep(forTimeInterval: 0.01) }
    if process.isRunning {
      guard kill(process.processIdentifier, SIGKILL) == 0 else { throw Failure.cleanup }
      let end = ContinuousClock.now.advanced(by: .seconds(2))
      while process.isRunning && ContinuousClock.now < end { Thread.sleep(forTimeInterval: 0.01) }
    }
  }
  guard !process.isRunning else { throw Failure.cleanup }
  process.waitUntilExit()
}

private func run() throws {
  let args = CommandLine.arguments
  guard args.count == 5, ["cycles", "absent", "cancel-inflated", "wrong-target"].contains(args[4])
  else {
    throw Failure.arguments
  }
  let qemu = URL(fileURLWithPath: args[1]).standardizedFileURL
  let image = URL(fileURLWithPath: args[2]).standardizedFileURL
  let root = URL(fileURLWithPath: args[3]).standardizedFileURL
  let mode = args[4]
  guard FileManager.default.isExecutableFile(atPath: qemu.path),
    FileManager.default.fileExists(atPath: image.path),
    !FileManager.default.fileExists(atPath: root.path)
  else { throw Failure.arguments }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  let serial = root.appendingPathComponent("serial.log")
  let errors = root.appendingPathComponent("qemu.stderr")
  guard FileManager.default.createFile(atPath: errors.path, contents: nil) else {
    throw Failure.arguments
  }
  let stderr = try FileHandle(forWritingTo: errors)
  let input = Pipe()
  let output = Pipe()
  let process = Process()
  process.executableURL = qemu
  process.arguments =
    [
      "-machine", "virt-10.2,secure=off,virtualization=off,gic-version=2",
      "-accel", "tcg,thread=single", "-cpu", "cortex-a72", "-m", "64M", "-smp", "1",
      "-nic", "none", "-display", "none", "-nodefaults", "-monitor", "none",
      "-qmp", "stdio", "-serial", "file:" + serial.path, "-S", "-no-reboot", "-kernel", image.path,
      "-global", "virtio-mmio.force-legacy=false", "-device", "virtio-rng-device",
    ] + (mode == "absent" ? [] : ["-device", "virtio-balloon-device"])
  process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C"]
  process.standardInput = input
  process.standardOutput = output
  process.standardError = stderr
  try JSONSerialization.data(
    withJSONObject: ["executable": qemu.path, "arguments": process.arguments ?? []],
    options: [.prettyPrinted, .sortedKeys]
  ).write(to: root.appendingPathComponent("invocation.json"))
  _ = signal(SIGPIPE, SIG_IGN)
  try process.run()
  defer {
    if process.isRunning { try? stop(process) }
    try? input.fileHandleForReading.close()
    try? input.fileHandleForWriting.close()
    try? output.fileHandleForReading.close()
    try? output.fileHandleForWriting.close()
    try? stderr.close()
  }
  // Close parent's child ends, so EOF/error detection reflects real child lifetime.
  try input.fileHandleForReading.close()
  try output.fileHandleForWriting.close()
  var primary: (any Error)?
  var observations: [UInt64] = []
  let deadline = ContinuousClock.now.advanced(by: .seconds(80))
  var serialExpected = "IRQ_PASS\nDMA_PASS\n"
  func serialText() throws -> String {
    guard FileManager.default.fileExists(atPath: serial.path) else { return "" }
    let data = try Data(contentsOf: serial)
    guard data.count <= 8192 else { throw LabError.framing }
    return String(decoding: data, as: UTF8.self)
  }
  func waitSerial(_ marker: String) throws {
    serialExpected += marker
    while ContinuousClock.now < deadline {
      let text = try serialText()
      guard serialExpected.hasPrefix(text) || text.hasPrefix(serialExpected) else {
        throw Failure.mismatch
      }
      if text.hasPrefix(serialExpected) { return }
      guard process.isRunning else { throw LabError.disconnected }
      Thread.sleep(forTimeInterval: 0.002)
    }
    throw LabError.deadline
  }
  do {
    var client = try QMPClient(
      input: input.fileHandleForWriting.fileDescriptor,
      output: output.fileHandleForReading.fileDescriptor, deadline: deadline)
    try client.negotiate()
    if mode == "absent" {
      do {
        _ = try client.command("query-balloon")
        throw Failure.mismatch
      } catch LabError.rejected("DeviceNotActive") {}
    } else {
      let installed: UInt64 = 64 * 1024 * 1024
      let granule: UInt64 = 16384
      guard
        let budget = BalloonBudget(
          installedBytes: installed, minimumResidentBytes: installed - granule,
          granuleBytes: granule, maximumStepBytes: granule),
        let initial = try client.command("query-balloon"), initial == installed
      else { throw Failure.mismatch }
      observations.append(initial)
      try client.command("cont")
      if mode == "wrong-target" {
        try waitSerial("HOST_READY\n")
        // Deliberate fault: bypass the conservative planner to test real guest refusal.
        try client.command("balloon", value: installed - 32768)
        guard let actual = try client.command("query-balloon"), actual == installed else {
          throw Failure.mismatch
        }
        observations.append(actual)
        try waitSerial("HOST_TARGET_MISMATCH\n")
      }
      for _ in 0..<(mode == "wrong-target" ? 0 : 10) {
        try waitSerial("HOST_READY\n")
        guard
          let inflate = budget.target(
            observedResidentBytes: observations.last!, requestedResidentBytes: installed - granule)
        else { throw Failure.mismatch }
        try client.command("balloon", value: inflate)
        try waitSerial("HOST_INFLATED\n")
        // QMP request completion alone is insufficient; query reflects guest-written actual.
        guard let actual = try client.command("query-balloon"), actual == inflate else {
          throw Failure.mismatch
        }
        observations.append(actual)
        if mode == "cancel-inflated" { break }
        guard
          let deflate = budget.target(
            observedResidentBytes: actual, requestedResidentBytes: installed)
        else { throw Failure.mismatch }
        try client.command("balloon", value: deflate)
        try waitSerial("HOST_DEFLATED\n")
        guard let actual = try client.command("query-balloon"), actual == deflate else {
          throw Failure.mismatch
        }
        observations.append(actual)
      }
      if mode == "cycles" || mode == "wrong-target" {
        if mode == "cycles" {
          try waitSerial("BALLOON_PASS\nGUEST_PASS\n")
          try client.command("quit")
        }
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        while process.isRunning && ContinuousClock.now < end {
          Thread.sleep(forTimeInterval: 0.01)
        }
        guard !process.isRunning, process.terminationReason == .exit,
          process.terminationStatus == 0, try serialText() == serialExpected
        else { throw Failure.mismatch }
      }
    }
  } catch { primary = error }
  var cleanupError: (any Error)?
  do { try stop(process) } catch { cleanupError = error }
  try? input.fileHandleForWriting.close()
  try? output.fileHandleForReading.close()
  try? stderr.close()
  let diagnostic = try String(contentsOf: errors, encoding: .utf8)
  let warning =
    "qemu-system-aarch64: warning: Balloon used with backing page size > 4kiB, this may not be reliable\n"
  var qualified = diagnostic
  let expectWarning =
    ["cycles", "cancel-inflated"].contains(mode) && sysconf(Int32(_SC_PAGESIZE)) > 4096
  let receipt: [String: Any] = [
    "mode": mode, "observedLogicalBytes": observations,
    "completedCycles": mode == "cycles" && primary == nil ? 10 : 0,
    "physicalReleasedBytes": NSNull(), "backingPageWarning": expectWarning,
    "ownedChildJoined": !process.isRunning,
    "primaryError": primary.map(String.init(describing:)) ?? "",
    "cleanupError": cleanupError.map(String.init(describing:)) ?? "",
  ]
  try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
    .write(to: root.appendingPathComponent("result.json"))
  // Preserve execution/cleanup failures before applying stricter expected-output validation.
  guard primary == nil, cleanupError == nil else { throw primary ?? cleanupError! }
  if expectWarning {
    guard qualified.components(separatedBy: warning).count == 2 else { throw Failure.mismatch }
    qualified = qualified.replacingOccurrences(of: warning, with: "")
  }
  if mode == "absent" || mode == "cancel-inflated" {
    // This is an owned-child intentional termination, not guest memory reuse/recovery success.
    let termination = "qemu-system-aarch64: terminating on signal 15 from pid "
    guard let range = qualified.range(of: termination),
      qualified[..<range.lowerBound].isEmpty,
      qualified[range.upperBound...].hasPrefix(String(getpid()) + " ")
    else { throw Failure.mismatch }
  } else if !qualified.isEmpty {
    throw Failure.mismatch
  }
  print("PASS host balloon " + mode + "; physical reclaim unverified")
}

do { try run() } catch {
  print("Host balloon refused: \(error)")
  exit(1)
}
