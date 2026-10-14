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
    ("FramePositive", []),
    ("MappedPositive", []),
    (
      "MappedEscape",
      [
        "4:36: error: instance method 'withValue' requires that 'Span<Int>' conform to 'Escapable'"
      ]
    ),
    (
      "MappedRelease",
      [
        "5:10: error: overlapping accesses to 'value', but modification requires exclusive access [#ExclusivityViolation]"
      ]
    ),
    ("MappedTake", ["5:37: error: 'consume' can only be used to partially consume storage"]),
    ("MappedReplace", ["4:27: error: cannot assign through subscript: subscript is get-only"]),
    ("MappedCopy", ["4:15: error: 'copy' cannot be applied to noncopyable types"]),
    (
      "MappedSendable",
      ["5:3: error: type 'MappedValue<Int>' does not conform to the 'Sendable' protocol"]
    ),
    (
      "MappedElementEscape",
      ["3:14: error: type 'Span<UInt8>' does not conform to protocol 'Escapable'"]
    ),
    ("FrameCopy", ["7:19: error: 'copy' cannot be applied to noncopyable types"]),
    ("FrameDoubleRelease", ["5:24: error: 'first' consumed more than once"]),
    ("FrameEscape", ["3:7: error: lifetime-dependent variable 'saved' escapes its scope"]),
    ("FrameAlias", ["4:7: error: 'loan' used after consume"]),
    (
      "FrameReset",
      [
        "4:53: error: overlapping accesses to 'metadata', but modification requires exclusive access; consider copying to a local variable [#ExclusivityViolation]"
      ]
    ),
    ("TypedOwnerOuter", ["4:7: error: lifetime-dependent variable 'saved' escapes its scope"]),
    ("TypedNestedOwner", ["4:65: error: lifetime-dependent variable 'outer' escapes its scope"]),
    ("TypedRemainderAlias", ["4:72: error: lifetime-dependent variable 'rest' escapes its scope"]),
    (
      "TypedEscape",
      [
        "4:13: error: instance method 'withTypedAllocation(of:capacity:_:)' requires that 'Span<UInt64>' conform to 'Escapable'"
      ]
    ),
    ("TypedOuter", ["4:7: error: lifetime-dependent variable 'saved' escapes its scope"]),
    (
      "TypedReenter",
      [
        "4:7: error: overlapping accesses to 'arena', but modification requires exclusive access [#ExclusivityViolation]"
      ]
    ),
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
