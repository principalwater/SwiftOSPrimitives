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
  let compiler = URL(fileURLWithPath: args[1]).standardizedFileURL
  let root = URL(fileURLWithPath: args[2]).standardizedFileURL
  let scratch = URL(fileURLWithPath: args[3]).standardizedFileURL.appendingPathComponent(
    UUID().uuidString)
  let files = FileManager.default
  guard files.isExecutableFile(atPath: compiler.path) else { throw CheckFailure.arguments }
  try files.createDirectory(at: scratch, withIntermediateDirectories: true)

  func run(_ name: String, executable: URL, arguments: [String], expectedError: String? = nil)
    throws
  {
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
    if let expectedError {
      let text = String(decoding: try Data(contentsOf: log), as: UTF8.self)
      guard child.terminationReason == .exit, child.terminationStatus != 0,
        text.contains(expectedError)
      else { throw CheckFailure.refused(name + ": " + text) }
      print("PASS \(name): expected compiler refusal")
      return
    }
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
    guard let target = targetInfo?["target"] as? [String: Any],
      let triple = target["triple"] as? String,
      let architecture = triple.split(separator: "-").first
    else { throw CheckFailure.refused("Missing compiler target") }
    let systemHeaders = "/usr/include"
    let architectureHeaders = systemHeaders + "/" + String(architecture) + "-linux-gnu"
    let names = ["unistd.h", "sys/mman.h", "errno.h", "stdio.h", "stdlib.h", "string.h", "fcntl.h"]
    var map = "module NativePOSIX [system] {\n"
    for name in names {
      let candidates = [systemHeaders, architectureHeaders].map { $0 + "/" + name }
      guard let path = candidates.first(where: { files.fileExists(atPath: $0) }) else {
        throw CheckFailure.refused("Missing native POSIX header: " + name)
      }
      map += "  header \"" + path + "\"\n"
    }
    map += "  export *\n}\n"
    // Import OS declarations only; the general SwiftGlibc umbrella also imports unsupported tgmath.
    let boundMap = scratch.appendingPathComponent("NativePOSIX.modulemap")
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
    let pollingIR = scratch.appendingPathComponent(target + "-polling.ll")
    try run(
      target + "-polling", executable: compiler,
      arguments: common + embedded + [
        "-no-allocations", "-target", target, "-emit-ir",
        root.appendingPathComponent("Examples/RegisterTrace/PollingTrace.swift").path,
        "-o", pollingIR.path,
      ])
    let polling = try String(contentsOf: pollingIR, encoding: .utf8)
    let pollingLines = polling.split(separator: "\n", omittingEmptySubsequences: false)
    guard
      let pollingStart = pollingLines.firstIndex(where: {
        $0.hasPrefix("define ") && $0.contains(" @uart_poll_volatile(") && $0.hasSuffix("{")
      }), let pollingEnd = pollingLines[(pollingStart + 1)...].firstIndex(of: "}")
    else {
      throw CheckFailure.refused("Missing volatile polling entry")
    }
    let pollingBody = pollingLines[(pollingStart + 1)..<pollingEnd]
    var block = ""
    var loadBlocks = Set<String>()
    var selfBranches = Set<String>()
    let targets = try NSRegularExpression(pattern: #"label %([-A-Za-z$._0-9]+)"#)
    for instruction in pollingBody {
      if instruction.range(of: #"^[-A-Za-z$._0-9]+:"#, options: .regularExpression) != nil {
        block = String(instruction.prefix(while: { $0 != ":" }))
      }
      if instruction.contains("load atomic volatile i8") { loadBlocks.insert(block) }
      if instruction.contains("br i1") {
        let line = String(instruction)
        for match in targets.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
          if let range = Range(match.range(at: 1), in: line), String(line[range]) == block {
            selfBranches.insert(block)
          }
        }
      }
    }
    guard pollingBody.filter({ $0.contains("load atomic volatile i8") }).count == 1,
      !loadBlocks.intersection(selfBranches).isEmpty,
      !pollingBody.contains(where: { $0.contains("call ") || $0.contains("invoke ") })
    else {
      throw CheckFailure.refused("Volatile polling load/loop contract")
    }
    print("PASS \(target): volatile polling retains a load and conditional backedge")

    try run(
      target + "-assembly", executable: compiler,
      arguments: common + embedded + [
        "-no-allocations", "-target", target, "-emit-assembly", trace, "-o",
        scratch.appendingPathComponent(target + ".s").path,
      ])
  }

  let arenaSources = [
    root.appendingPathComponent("Sources/BoundedMemory/ScratchArena.swift").path,
    root.appendingPathComponent("Examples/EmbeddedArenaProbe/main.swift").path,
  ]
  let lifetimes = ["-enable-experimental-feature", "Lifetimes"]
  let arenaImage = scratch.appendingPathComponent("EmbeddedArenaProbe")
  try run(
    "EmbeddedArena", executable: compiler,
    arguments: host + embedded + lifetimes + ["-no-allocations", "-D", "BOUNDEDMEMORY_STANDALONE"]
      + arenaSources + ["-o", arenaImage.path])
  try run("ArenaExecution", executable: arenaImage, arguments: [])

  try run(
    "AllocatingControl", executable: compiler,
    arguments: common + embedded + [
      "-no-allocations", "-target", "x86_64-unknown-none-elf",
      "-emit-ir",
      root.appendingPathComponent("Examples/EmbeddedArenaProbe/AllocatingControl.swift").path,
      "-o", scratch.appendingPathComponent("AllocatingControl.ll").path,
    ],
    expectedError: "error: cannot use allocating type '_ContiguousArrayStorage<UInt8>'")

  #if canImport(Darwin) && arch(arm64)
    let instructions = scratch.appendingPathComponent("InstructionProbe")
    try run(
      "InstructionProbe", executable: compiler,
      arguments: host + embedded + [
        "-no-allocations",
        root.appendingPathComponent("Examples/InstructionProbe/main.swift").path,
        "-o", instructions.path,
      ])
    try run("InstructionExecution", executable: instructions, arguments: [])
  #endif

  // This optional compiler experiment is a whole-object audit, not a kernel/module loader.
  if let llvmPath = ProcessInfo.processInfo.environment["KERNEL_LLVM_BIN"] {
    let llvm = URL(fileURLWithPath: llvmPath)
    for name in ["opt", "llc", "llvm-nm", "llvm-objdump"] {
      let tool = llvm.appendingPathComponent(name)
      guard files.isExecutableFile(atPath: tool.path) else {
        throw CheckFailure.refused("Missing requested LLVM tool: " + name)
      }
      try run("Version-" + name, executable: tool, arguments: ["--version"])
    }
    for target in ["aarch64-none-none-elf", "x86_64-unknown-none-elf"] {
      let prefix = "Arena-" + target
      let original = scratch.appendingPathComponent(prefix + ".ll")
      try run(
        prefix, executable: compiler,
        arguments: common + embedded + lifetimes + [
          "-no-allocations", "-target", target, "-emit-ir", arenaSources[0],
          root.appendingPathComponent("Examples/ArenaTrace/ArenaTrace.swift").path,
          "-o", original.path,
        ])
      let reachable = scratch.appendingPathComponent(prefix + "-reachable.ll")
      try run(
        prefix + "-Reachable", executable: llvm.appendingPathComponent("opt"),
        arguments: [
          "-verify-each", "-passes=internalize<preserve-gv=arena_trace>,globaldce", "-S",
          original.path, "-o", reachable.path,
        ])
      // LLVM function attributes override llc -mattr. Apply the explicit experiment profile here.
      let features =
        target.hasPrefix("x86")
        ? "-mmx,-sse,-sse2,-sse3,-ssse3,-sse4.1,-sse4.2,-avx,-avx2,-avx512f,-x87,+soft-float"
        : "-fp-armv8,-neon,-sve,-sve2,-sme,-sme2"
      let featurePattern = try NSRegularExpression(pattern: #""target-features"="[^"]*""#)
      let text = try String(contentsOf: reachable, encoding: .utf8)
      let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
      var changed = 0
      let profiled = lines.map { line -> String in
        guard line.hasPrefix("attributes #") else { return line }
        guard line.contains(#""target-features"="#) else { return line }
        changed += 1
        let adjusted = featurePattern.stringByReplacingMatches(
          in: line,
          range: NSRange(line.startIndex..., in: line),
          withTemplate: #""target-features"="$FEATURES""#.replacingOccurrences(
            of: "$FEATURES", with: features))
        return adjusted.replacingOccurrences(of: " = {", with: " = { noredzone")
      }.joined(separator: "\n")
      guard changed > 0 else { throw CheckFailure.refused("No target profile attributes") }
      let kernelIR = scratch.appendingPathComponent(prefix + "-profile.ll")
      try profiled.write(to: kernelIR, atomically: true, encoding: .utf8)
      let object = scratch.appendingPathComponent(prefix + ".o")
      let model = target.hasPrefix("x86") ? "kernel" : "small"
      try run(
        prefix + "-Object", executable: llvm.appendingPathComponent("llc"),
        arguments: [
          "-filetype=obj", "-code-model=" + model, kernelIR.path, "-o", object.path,
        ])
      try run(
        prefix + "-Imports", executable: llvm.appendingPathComponent("llvm-nm"),
        arguments: [
          "--undefined-only", object.path,
        ])
      let imports = try String(
        contentsOf: scratch.appendingPathComponent(prefix + "-Imports.log"),
        encoding: .utf8
      ).trimmingCharacters(in: .whitespacesAndNewlines)
      guard imports.isEmpty else { throw CheckFailure.refused("Object imports: " + imports) }
      try run(
        prefix + "-Assembly", executable: llvm.appendingPathComponent("llvm-objdump"),
        arguments: ["-d", "--no-show-raw-insn", object.path])
      let assembly = try String(
        contentsOf: scratch.appendingPathComponent(prefix + "-Assembly.log"),
        encoding: .utf8)
      let forbidden =
        target.hasPrefix("x86")
        ? #"%(?:xmm|ymm|zmm|mm)[0-9]+|%st(?:\(|\b)"#
        : #"\b(?:v[0-9]+\.[0-9]+[bhsd]|[bhsdqzp][0-9]+)\b"#
      // Match operands only: a hex instruction address such as `d0:` is not an FP register.
      let operands = assembly.split(separator: "\n").compactMap { line -> String? in
        guard line.range(of: #"^\s*[0-9a-f]+:\s"#, options: .regularExpression) != nil,
          let colon = line.firstIndex(of: ":")
        else { return nil }
        let instruction = line[line.index(after: colon)...]
        return String(instruction.split(separator: "<", maxSplits: 1)[0])
      }.joined(separator: "\n")
      guard operands.range(of: forbidden, options: .regularExpression) == nil else {
        throw CheckFailure.refused("Floating-point/vector register in " + target)
      }
      print("PASS \(prefix): whole object has no undefined symbols or FP/vector registers")

      let controlIR = scratch.appendingPathComponent(prefix + "-dependency.ll")
      try run(
        prefix + "-Dependency", executable: compiler,
        arguments: common + embedded + [
          "-no-allocations", "-target", target, "-emit-ir",
          root.appendingPathComponent("Examples/ArenaTrace/DependencyControl.swift").path,
          "-o", controlIR.path,
        ])
      let controlLive = scratch.appendingPathComponent(prefix + "-dependency-live.ll")
      try run(
        prefix + "-DependencyReachable", executable: llvm.appendingPathComponent("opt"),
        arguments: [
          "-verify-each", "-passes=internalize<preserve-gv=arena_trace>,globaldce", "-S",
          controlIR.path, "-o", controlLive.path,
        ])
      let controlObject = scratch.appendingPathComponent(prefix + "-dependency.o")
      try run(
        prefix + "-DependencyObject", executable: llvm.appendingPathComponent("llc"),
        arguments: ["-filetype=obj", controlLive.path, "-o", controlObject.path])
      try run(
        prefix + "-DependencyImports", executable: llvm.appendingPathComponent("llvm-nm"),
        arguments: ["--undefined-only", controlObject.path])
      let controlImports = try String(
        contentsOf: scratch.appendingPathComponent(prefix + "-DependencyImports.log"),
        encoding: .utf8)
      guard controlImports.contains(" U forbidden_dependency") else {
        throw CheckFailure.refused("Undefined dependency control was not retained")
      }
      print("PASS \(prefix): no-allocations alone allows the forbidden dependency control")

    }
  }

  print("Low-level evidence: \(scratch.path)")
}

do { try checkLowLevel() } catch {
  print("Low-level checks refused: \(error)")
  exit(1)
}
