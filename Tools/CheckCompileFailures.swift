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
  let compiler = URL(fileURLWithPath: arguments[1])
  let modules = arguments[2]
  let sources = URL(fileURLWithPath: arguments[3])
  let scratch = URL(fileURLWithPath: arguments[4]).appendingPathComponent(UUID().uuidString)
  let files = FileManager.default
  guard files.isExecutableFile(atPath: compiler.path) else { throw CheckError.arguments }
  try files.createDirectory(at: scratch, withIntermediateDirectories: true)

  let cases: [(String, String?)] = [
    ("PositiveControl", nil),
    ("CopyOwner", "consumed more than once"),
    ("EscapingBorrow", "escapes"),
    ("ReleaseDuringBorrow", "overlapping accesses"),
    ("OuterBorrow", "lifetime"),
    ("MutableBorrow", "lifetime"),
    ("TaskCapture", "capture"),
  ]
  for (name, diagnostic) in cases {
    let log = scratch.appendingPathComponent(name + ".log")
    guard files.createFile(atPath: log.path, contents: nil) else {
      throw CheckError.compilation(name)
    }
    let output = try FileHandle(forWritingTo: log)
    defer { try? output.close() }
    let process = Process()
    process.executableURL = compiler
    process.arguments = [
      "-swift-version", "6", "-emit-sil", "-I", modules,
      "-module-cache-path", scratch.appendingPathComponent("module-cache").path,
      sources.appendingPathComponent(name + ".swift").path,
      "-o", scratch.appendingPathComponent(name + ".sil").path,
    ]
    if let sdk = ProcessInfo.processInfo.environment["SDKROOT"] {
      process.arguments?.append(contentsOf: ["-sdk", sdk])
    }
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
    if let diagnostic {
      guard process.terminationReason == .exit, process.terminationStatus != 0,
        text.contains("error:"), text.localizedCaseInsensitiveContains(diagnostic)
      else { throw CheckError.compilation(name + ": " + text) }
    } else {
      guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        throw CheckError.compilation(name + ": " + text)
      }
    }
    print("PASS \(name)")
  }
  print("Compiler evidence: \(scratch.path)")
}

do { try runChecks() } catch {
  print("Compiler ownership checks failed: \(error)")
  exit(1)
}
