import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif os(Windows)
  import WinSDK
  import ucrt
#else
  import Musl
#endif

enum CheckError: Error {
  case arguments
  case compilation(String)
  case timeout, outputTooLarge
}
#if os(Windows)
  func waitForCompiler(_ process: Process) throws -> DWORD {
    var child: HANDLE?
    let current = GetCurrentProcess()
    guard
      DuplicateHandle(
        current, process.processHandle, current, &child, 0, false,
        DWORD(DUPLICATE_SAME_ACCESS)), let child
    else {
      let code = GetLastError()
      // The original Foundation-owned handle still pins this exact child on duplication failure.
      _ = TerminateProcess(process.processHandle, 1)
      _ = WaitForSingleObject(process.processHandle, 2_000)
      throw CheckError.compilation("Pin compiler handle failed: \(code)")
    }
    defer { _ = CloseHandle(child) }
    let result = WaitForSingleObject(child, 30_000)
    if result != DWORD(WAIT_OBJECT_0) {
      let code = GetLastError()
      _ = TerminateProcess(child, 1)
      let cleanup = WaitForSingleObject(child, 2_000)
      guard cleanup == DWORD(WAIT_OBJECT_0) else {
        throw CheckError.compilation("Compiler cleanup did not finish within two seconds")
      }
      if result == DWORD(WAIT_TIMEOUT) { throw CheckError.timeout }
      throw CheckError.compilation("Wait for compiler failed: \(code)")
    }
    var code: DWORD = 0
    guard GetExitCodeProcess(child, &code) else {
      throw CheckError.compilation("Compiler exit-code query failed: \(GetLastError())")
    }
    return code
  }
#endif
func runChecks() throws {
  let arguments = CommandLine.arguments
  guard arguments.count == 5 else { throw CheckError.arguments }
  let compiler = URL(fileURLWithPath: arguments[1])
  let modules = arguments[2]
  let sources = URL(fileURLWithPath: arguments[3])
  let scratch = URL(fileURLWithPath: arguments[4]).appendingPathComponent(UUID().uuidString)
  let files = FileManager.default
  #if os(Windows)
    guard files.fileExists(atPath: compiler.path) else { throw CheckError.arguments }
  #else
    guard files.isExecutableFile(atPath: compiler.path) else { throw CheckError.arguments }
  #endif
  try files.createDirectory(at: scratch, withIntermediateDirectories: true)

  let cases: [(String, [String])] = [
    ("CompilerVersion", []),
    ("PositiveControl", []),
    ("CopyOwner", ["4:7: error: 'region' consumed more than once"]),
    ("EscapingBorrow", ["4:26: error: lifetime-dependent variable 'bytes' escapes its scope"]),
    (
      "ReleaseDuringBorrow",
      [
        "6:10: error: overlapping accesses to 'region', but modification requires exclusive access [#ExclusivityViolation]"
      ]
    ),
    ("OuterBorrow", ["6:9: error: lifetime-dependent variable 'saved' escapes its scope"]),
    (
      "MutableBorrow",
      [
        "8:38: error: missing reinitialization of inout parameter 'inner' after consume",
        "5:32: error: lifetime-dependent variable 'outer' escapes its scope",
      ]
    ),
    ("TaskCapture", ["4:26: error: lifetime-dependent variable 'bytes' escapes its scope"]),
    ("SendOwner", ["6:3: error: type 'PageRegion' does not conform to the 'Sendable' protocol"]),
  ]
  for (name, expected) in cases {
    let log = scratch.appendingPathComponent(name + ".log")
    guard files.createFile(atPath: log.path, contents: nil) else {
      throw CheckError.compilation(name)
    }
    let output = try FileHandle(forWritingTo: log)
    defer { try? output.close() }
    let process = Process()
    process.executableURL = compiler
    var environment = ProcessInfo.processInfo.environment
    // A new compiler invocation must not inherit the parent's Swiftly proxy sentinel.
    environment.removeValue(forKey: "SWIFTLY_PROXY_IN_PROGRESS")
    process.environment = environment
    process.arguments = [
      "-swift-version", "6", "-emit-sil", "-I", modules,
      "-module-cache-path", scratch.appendingPathComponent("module-cache").path,
      sources.appendingPathComponent(name + ".swift").path,
      "-o", scratch.appendingPathComponent(name + ".sil").path,
    ]
    if let sdk = ProcessInfo.processInfo.environment["SDKROOT"] {
      process.arguments?.append(contentsOf: ["-sdk", sdk])
    }
    if name == "CompilerVersion" { process.arguments = ["-version"] }
    process.standardOutput = output
    process.standardError = output
    try process.run()
    #if os(Windows)
      let code = try waitForCompiler(process)
      let terminationStatus = Int32(bitPattern: code)
      // Match Foundation's classification of Windows abnormal termination, without its wait.
      let exitedNormally =
        code != 3
        && ![0x8000_0000, 0xC000_0000, 0xE000_0000].contains(
          code & 0xF000_0000)
    #else
      let deadline = ContinuousClock.now.advanced(by: .seconds(30))
      while process.isRunning && ContinuousClock.now < deadline {
        Thread.sleep(forTimeInterval: 0.01)
      }
      if process.isRunning {
        process.terminate()
        let cleanup = ContinuousClock.now.advanced(by: .seconds(2))
        while process.isRunning && ContinuousClock.now < cleanup {
          Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        throw CheckError.timeout
      }
      process.waitUntilExit()
      let terminationStatus = process.terminationStatus
      let exitedNormally = process.terminationReason == .exit
    #endif
    let size = try files.attributesOfItem(atPath: log.path)[.size] as? NSNumber
    guard let size, size.intValue <= 65_536 else { throw CheckError.outputTooLarge }
    let text = String(decoding: try Data(contentsOf: log), as: UTF8.self)
    if !expected.isEmpty {
      let actual = text.split(whereSeparator: \.isNewline).filter { $0.contains(": error:") }.map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
          .replacingOccurrences(of: "\\", with: "/")
      }
      let prefix =
        sources.appendingPathComponent(name + ".swift").path
        .replacingOccurrences(of: "\\", with: "/") + ":"
      guard exitedNormally, terminationStatus != 0,
        actual.sorted() == expected.map({ prefix + $0 }).sorted()
      else { throw CheckError.compilation(name + ": " + text) }
    } else {
      guard exitedNormally, terminationStatus == 0 else {
        throw CheckError.compilation(name + ": " + text)
      }
    }
    if name == "CompilerVersion" {
      guard text.contains("Swift version 6.4.1 ") else {
        throw CheckError.compilation("Expected Swift 6.4.1")
      }
      print(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    print("PASS \(name)")
  }
  print("Compiler evidence: \(scratch.path)")
}
do { try runChecks() } catch {
  print("Compiler ownership checks failed: \(error)")
  exit(1)
}
