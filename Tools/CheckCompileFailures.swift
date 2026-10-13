import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#else
  import Musl
#endif

enum CheckError: Error {
  case arguments
  case compilation(String)
  case timeout, outputTooLarge
}

func runChecks() throws {
  let arguments = CommandLine.arguments
  guard arguments.count == 5 else { throw CheckError.arguments }
  let compiler = URL(fileURLWithPath: arguments[1]).standardizedFileURL
  let modules = arguments[2]
  let sources = URL(fileURLWithPath: arguments[3]).standardizedFileURL
  let scratch = URL(fileURLWithPath: arguments[4]).standardizedFileURL.appendingPathComponent(
    UUID().uuidString)
  let files = FileManager.default
  guard files.isExecutableFile(atPath: compiler.path) else { throw CheckError.arguments }
  try files.createDirectory(at: scratch, withIntermediateDirectories: true)

  let cases: [(String, [String])] = [
    ("CompilerVersion", []),
    ("ArenaPositive", []),
    ("ArenaOuter", ["4:7: error: lifetime-dependent variable 'saved' escapes its scope"]),
    (
      "ArenaSwap",
      [
        "8:5: error: global function 'swap' requires that 'MutableSpan<UInt8>' conform to 'Escapable'"
      ]
    ),
    ("ArenaCopy", ["6:7: error: 'arena' consumed more than once"]),
    ("ArenaEscape", ["4:7: error: lifetime-dependent variable 'saved' escapes its scope"]),
    (
      "ArenaReenter",
      [
        "6:7: error: overlapping accesses to 'arena', but modification requires exclusive access [#ExclusivityViolation]"
      ]
    ),
    (
      "ArenaRemainder",
      [
        "6:13: error: instance method 'withAllocation(byteCount:alignment:_:)' requires that 'ScratchArena' conform to 'Escapable'"
      ]
    ),
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
    ("ThrowingBorrow", ["6:32: error: lifetime-dependent variable 'bytes' escapes its scope"]),
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
      "-swift-version", "6", "-enable-experimental-feature", "Lifetimes", "-emit-sil", "-I",
      modules,
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
    let size = try files.attributesOfItem(atPath: log.path)[.size] as? NSNumber
    guard let size, size.intValue <= 65_536 else { throw CheckError.outputTooLarge }
    let text = String(decoding: try Data(contentsOf: log), as: UTF8.self)
    if !expected.isEmpty {
      let actual = text.split(separator: "\n").filter { $0.contains(": error:") }.map(String.init)
      let prefix = sources.appendingPathComponent(name + ".swift").path + ":"
      guard process.terminationReason == .exit, process.terminationStatus != 0,
        actual.sorted() == expected.map({ prefix + $0 }).sorted()
      else { throw CheckError.compilation(name + ": " + text) }
    } else {
      guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        throw CheckError.compilation(name + ": " + text)
      }
    }
    if name == "CompilerVersion" { print(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
    print("PASS \(name)")
  }
  print("Compiler evidence: \(scratch.path)")
}

do { try runChecks() } catch {
  print("Compiler ownership checks failed: \(error)")
  exit(1)
}
