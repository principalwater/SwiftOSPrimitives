import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

enum CheckFailure: Error {
  case arguments
  case refused(String)
  case deadline, oversizedEvidence
}

func checkLowLevel() throws {
  let args = CommandLine.arguments
  guard args.count == 4 else { throw CheckFailure.arguments }
  let compiler = URL(fileURLWithPath: args[1])
  let root = URL(fileURLWithPath: args[2])
  let scratch = URL(fileURLWithPath: args[3]).appendingPathComponent(UUID().uuidString)
  let files = FileManager.default
  guard files.isExecutableFile(atPath: compiler.path) else { throw CheckFailure.arguments }
  try files.createDirectory(at: scratch, withIntermediateDirectories: true)

  func run(_ name: String, executable: URL, arguments: [String]) throws {
    let log = scratch.appendingPathComponent(name + ".log")
    guard files.createFile(atPath: log.path, contents: nil) else { throw CheckFailure.arguments }
    let output = try FileHandle(forWritingTo: log)
    defer { try? output.close() }
    let child = Process()
    child.executableURL = executable
    child.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment.removeValue(forKey: "SWIFTLY_PROXY_IN_PROGRESS")
    child.environment = environment
    child.standardOutput = output
    child.standardError = output
    child.standardInput = FileHandle.nullDevice
    try JSONSerialization.data(
      withJSONObject: [
        "executable": executable.path, "arguments": arguments,
        "SDKROOT": environment["SDKROOT"] ?? "",
      ], options: [.prettyPrinted, .sortedKeys]
    ).write(
      to: scratch.appendingPathComponent(name + "-invocation.json"))
    try child.run()
    let end = ContinuousClock.now.advanced(by: .seconds(60))
    while child.isRunning && ContinuousClock.now < end { Thread.sleep(forTimeInterval: 0.02) }
    if child.isRunning {
      child.terminate()
      let cleanup = ContinuousClock.now.advanced(by: .seconds(2))
      while child.isRunning && ContinuousClock.now < cleanup { Thread.sleep(forTimeInterval: 0.02) }
      if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
      child.waitUntilExit()
      throw CheckFailure.deadline
    }
    child.waitUntilExit()
    let size = try files.attributesOfItem(atPath: log.path)[.size] as? NSNumber
    guard let size, size.intValue <= 262_144 else { throw CheckFailure.oversizedEvidence }
    guard child.terminationReason == .exit, child.terminationStatus == 0 else {
      throw CheckFailure.refused(
        name + ": " + String(decoding: try Data(contentsOf: log), as: UTF8.self))
    }
    print("PASS \(name)")
  }

  let common = [
    "-swift-version", "6", "-O", "-wmo", "-parse-as-library", "-strict-memory-safety",
    "-warnings-as-errors", "-module-cache-path", scratch.appendingPathComponent("modules").path,
  ]
  try run("CompilerVersion", executable: compiler, arguments: ["--version"])
  var host = common
  if let sdk = ProcessInfo.processInfo.environment["SDKROOT"] { host += ["-sdk", sdk] }
  let embedded = ["-enable-experimental-feature", "Embedded"]
  var embeddedHost = host + embedded
  #if os(Linux)
    try run("TargetInfo", executable: compiler, arguments: ["-print-target-info"])
    let targetInfo =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: scratch.appendingPathComponent("TargetInfo.log"))) as? [String: Any]
    guard let paths = targetInfo?["paths"] as? [String: Any],
      let resourcePath = paths["runtimeResourcePath"] as? String,
      let target = targetInfo?["target"] as? [String: Any],
      let triple = target["triple"] as? String,
      let architecture = triple.split(separator: "-").first
    else { throw CheckFailure.refused("Missing compiler resource path") }
    let platform = URL(fileURLWithPath: resourcePath).appendingPathComponent("linux")
      .appendingPathComponent(String(architecture))
    let moduleMap = platform.appendingPathComponent("glibc.modulemap")
    guard files.fileExists(atPath: moduleMap.path) else {
      throw CheckFailure.refused("Native Glibc declaration map unavailable: " + moduleMap.path)
    }
    let systemHeaders = "/usr/include"
    let architectureHeaders = systemHeaders + "/" + String(architecture) + "-linux-gnu"
    guard files.fileExists(atPath: systemHeaders + "/assert.h"),
      files.fileExists(atPath: architectureHeaders + "/bits/wordsize.h")
    else { throw CheckFailure.refused("Native glibc development headers unavailable") }
    // Module-map headers resolve relative to the map, independently of include search paths.
    var map = try String(contentsOf: moduleMap, encoding: .utf8)
    let pattern = try NSRegularExpression(pattern: #"\bheader "([^"]+)""#)
    let matches = pattern.matches(in: map, range: NSRange(map.startIndex..., in: map))
    for match in matches.reversed() {
      guard let range = Range(match.range(at: 1), in: map) else { throw CheckFailure.arguments }
      let name = String(map[range])
      let candidates = [platform.path, systemHeaders, architectureHeaders].map { $0 + "/" + name }
      guard let path = candidates.first(where: { files.fileExists(atPath: $0) }) else {
        throw CheckFailure.refused("Missing module-map header: " + name)
      }
      map.replaceSubrange(range, with: path)
    }
    let boundMap = scratch.appendingPathComponent("glibc.modulemap")
    try map.write(to: boundMap, atomically: true, encoding: .utf8)
    embeddedHost += ["-Xcc", "-fmodule-map-file=" + boundMap.path]
    // Embedded deliberately omits system include paths; this is a native user-space fixture.
    embeddedHost += [
      "-Xcc", "-isystem", "-Xcc", systemHeaders,
      "-Xcc", "-isystem", "-Xcc", architectureHeaders,
    ]
  #endif
  let pages = try files.contentsOfDirectory(
    atPath: root.appendingPathComponent("Sources/PageMemory").path
  )
  .filter { $0.hasSuffix(".swift") }.sorted().map {
    root.appendingPathComponent("Sources/PageMemory").appendingPathComponent($0).path
  }
  let pageImage = scratch.appendingPathComponent("EmbeddedPageProbe")
  try run(
    "EmbeddedPages", executable: compiler,
    arguments: embeddedHost + ["-D", "PAGEMEMORY_STANDALONE"] + pages + [
      root.appendingPathComponent("Examples/EmbeddedPageProbe/main.swift").path, "-o",
      pageImage.path,
    ])
  try run("EmbeddedPageExecution", executable: pageImage, arguments: [])

  let trace = root.appendingPathComponent("Examples/RegisterTrace/RegisterTrace.swift").path
  let traceImage = scratch.appendingPathComponent("RegisterTrace")
  try run(
    "EmbeddedRegisters", executable: compiler,
    arguments: embeddedHost + [
      trace, root.appendingPathComponent("Examples/RegisterTrace/main.swift").path,
      "-o", traceImage.path,
    ])
  try run("RegisterExecution", executable: traceImage, arguments: [])

  for target in ["aarch64-none-none-elf", "x86_64-unknown-none-elf"] {
    let ir = scratch.appendingPathComponent(target + ".ll")
    try run(
      target, executable: compiler,
      arguments: common + embedded + [
        "-no-allocations", "-target", target, "-emit-ir", trace, "-o", ir.path,
      ])
    let contents = try String(contentsOf: ir, encoding: .utf8)
    let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
    guard
      let start = lines.firstIndex(where: {
        $0.hasPrefix("define ") && $0.contains(" @register_trace32(") && $0.hasSuffix("{")
      }), let end = lines[(start + 1)...].firstIndex(of: "}")
    else { throw CheckFailure.refused("Missing exported trace body") }
    let instructions = lines[(start + 1)..<end]
    let loads = instructions.filter { $0.contains("load atomic volatile i32") }
    let stores = instructions.filter { $0.contains("store atomic volatile i32") }
    let accesses = instructions.filter { $0.contains("atomic volatile") }
    guard loads.count == 2, stores.count == 2,
      accesses.count == 4,
      accesses.map({ $0.contains("store atomic volatile i32") }) == [true, false, true, false],
      accesses.allSatisfy({ $0.contains("monotonic, align 4") }),
      !instructions.contains(where: { $0.contains("call ") || $0.contains("invoke ") })
    else { throw CheckFailure.refused("Volatile count or call-free contract: " + target) }
    print("PASS \(target): two volatile loads, two volatile stores, no calls")
    try run(
      target + "-assembly", executable: compiler,
      arguments: common + embedded + [
        "-no-allocations", "-target", target, "-emit-assembly", trace, "-o",
        scratch.appendingPathComponent(target + ".s").path,
      ])
  }
  print("Low-level evidence: \(scratch.path)")
}

do { try checkLowLevel() } catch {
  print("Low-level checks refused: \(error)")
  exit(1)
}
