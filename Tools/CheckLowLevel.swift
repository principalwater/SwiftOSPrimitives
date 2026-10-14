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

// ELF flags are audited declarations; this single-CPU guest has no MMU-enforced W^X policy.
func auditGuestELF(_ path: URL) throws {
  let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
  guard let size = attributes[.size] as? NSNumber, size.intValue <= 16 * 1024 * 1024 else {
    throw CheckFailure.refused("ELF size")
  }
  let data = try Data(contentsOf: path)
  func read(_ offset: Int, _ width: Int) throws -> UInt64 {
    guard offset >= 0, width > 0, width <= 8, offset <= data.count - width else {
      throw CheckFailure.refused("ELF extent")
    }
    var value: UInt64 = 0
    for index in 0..<width { value |= UInt64(data[offset + index]) << (index * 8) }
    return value
  }
  guard data.count >= 64, try read(0, 4) == 0x464c_457f,
    data[4] == 2, data[5] == 1, data[6] == 1,
    try read(16, 2) == 2, try read(18, 2) == 183, try read(20, 4) == 1,
    try read(52, 2) == 64
  else { throw CheckFailure.refused("ELF identity") }
  let entry = try read(24, 8)
  let programOffset = try read(32, 8)
  let sectionOffset = try read(40, 8)
  let programCount = try read(56, 2)
  let sectionCount = try read(60, 2)
  guard try read(54, 2) == 56, try read(58, 2) == 64,
    programCount > 0, programCount <= 32, sectionCount > 0, sectionCount <= 128,
    programOffset >= 64, sectionOffset >= 64,
    programOffset <= UInt64(data.count), sectionOffset <= UInt64(data.count),
    programCount * 56 <= UInt64(data.count) - programOffset,
    sectionCount * 64 <= UInt64(data.count) - sectionOffset
  else { throw CheckFailure.refused("ELF tables") }
  var executableEntry = false
  var stack = false
  var loads: [Range<UInt64>] = []
  for index in 0..<Int(programCount) {
    let offset = Int(programOffset) + index * 56
    let type = try read(offset, 4)
    let flags = try read(offset + 4, 4)
    guard type != 2, type != 3, type != 7 else { throw CheckFailure.refused("ELF dynamic/TLS") }
    guard type == 1 || type == 0x6474_e551 else {
      throw CheckFailure.refused("ELF segment type")
    }
    guard flags & 3 != 3 else { throw CheckFailure.refused("ELF writable executable segment") }
    if type == 0x6474_e551 {
      guard flags == 6, !stack else { throw CheckFailure.refused("ELF entry/stack") }
      stack = true
    }
    if type == 1 {
      let fileOffset = try read(offset + 8, 8)
      let address = try read(offset + 16, 8)
      let physicalAddress = try read(offset + 24, 8)
      let fileBytes = try read(offset + 32, 8)
      let memoryBytes = try read(offset + 40, 8)
      guard fileOffset <= UInt64(data.count), fileBytes <= UInt64(data.count) - fileOffset,
        physicalAddress == address, memoryBytes >= fileBytes,
        address >= 0x4008_0000, address < 0x4400_0000,
        memoryBytes <= 0x4400_0000 - address
      else { throw CheckFailure.refused("ELF load extent") }
      let extent = address..<(address + memoryBytes)
      guard !loads.contains(where: { $0.overlaps(extent) }) else {
        throw CheckFailure.refused("ELF overlapping loads")
      }
      loads.append(extent)
      if flags & 1 != 0 && entry % 4 == 0 && entry >= address && entry - address < fileBytes {
        executableEntry = true
      }
    }
  }
  guard stack, executableEntry else { throw CheckFailure.refused("ELF entry/stack") }
  for index in 0..<Int(sectionCount) {
    let offset = Int(sectionOffset) + index * 64
    let type = try read(offset + 4, 4)
    let bytes = try read(offset + 32, 8)
    guard bytes == 0 || ![4, 9, 6, 11, 19, 0x4000_0014].contains(type) else {
      throw CheckFailure.refused("ELF relocation/dynamic section")
    }
    if type != 8 {
      let fileOffset = try read(offset + 24, 8)
      guard fileOffset <= UInt64(data.count), bytes <= UInt64(data.count) - fileOffset else {
        throw CheckFailure.refused("ELF section extent")
      }
    }
  }
}

func checkELFRefusals(_ image: URL, scratch: URL) throws {
  let original = try Data(contentsOf: image)
  func word(_ offset: Int) -> Int {
    (0..<8).reduce(0) { $0 | (Int(original[offset + $1]) << ($1 * 8)) }
  }
  func field(_ value: UInt64, width: Int = 8) -> Data {
    Data((0..<width).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
  }
  let program = word(32)
  let section = word(40) + 64
  let address = UInt64(word(program + 16))
  let fileBytes = UInt64(word(program + 32))
  for (name, changes, expected) in [
    ("Entry", [(24, field(0))], "ELF entry/stack"),
    ("UnalignedEntry", [(24, field(address + 1))], "ELF entry/stack"),
    (
      "BSSentry",
      [
        (24, field(address + fileBytes + 4 - fileBytes % 4)),
        (program + 40, field(fileBytes + 16)),
      ], "ELF entry/stack"
    ),
    ("WX", [(program + 4, field(7, width: 4))], "ELF writable executable segment"),
    ("Dynamic", [(program, field(2, width: 4))], "ELF dynamic/TLS"),
    ("UnknownSegment", [(program, field(6, width: 4))], "ELF segment type"),
    ("Relocation", [(section + 4, field(4, width: 4))], "ELF relocation/dynamic section"),
    (
      "PackedRelocation", [(section + 4, field(19, width: 4))],
      "ELF relocation/dynamic section"
    ),
    ("Count", [(56, field(65535, width: 2))], "ELF tables"),
    ("TableExtent", [(32, field(UInt64(original.count - 1)))], "ELF tables"),
    ("Machine", [(18, field(62, width: 2))], "ELF identity"),
    ("SharedImage", [(16, field(3, width: 2))], "ELF identity"),
    ("Physical", [(program + 24, field(0x0900_0000))], "ELF load extent"),
    (
      "BelowRAM",
      [
        (program + 16, field(0x4000_0000)),
        (program + 24, field(0x4000_0000)),
      ], "ELF load extent"
    ),
    ("RAMextent", [(program + 40, field(0x4400_0000))], "ELF load extent"),
    ("FileExtent", [(program + 32, field(UInt64(original.count + 1)))], "ELF load extent"),
    ("FileOffset", [(program + 8, field(UInt64(original.count + 1)))], "ELF load extent"),
    (
      "SectionOffset", [(section + 24, field(UInt64(original.count + 1)))],
      "ELF section extent"
    ),
    ("MissingStack", [(56, field(3, width: 2))], "ELF entry/stack"),
    (
      "DuplicateStack",
      [
        (program + 56, field(0x6474_e551, width: 4)),
        (program + 60, field(6, width: 4)),
      ], "ELF entry/stack"
    ),
    (
      "Overlap", [(program + 72, field(address)), (program + 80, field(address))],
      "ELF overlapping loads"
    ),
  ] {
    var mutated = original
    for (offset, replacement) in changes {
      mutated.replaceSubrange(offset..<(offset + replacement.count), with: replacement)
    }
    let path = scratch.appendingPathComponent("InvalidELF-" + name + ".bin")
    try mutated.write(to: path)
    do {
      try auditGuestELF(path)
    } catch CheckFailure.refused(let reason) {
      guard reason == expected else { throw CheckFailure.refused(name + ": " + reason) }
      print("PASS ELF refusal: " + name)
      continue
    }
    throw CheckFailure.refused("Invalid ELF admitted: " + name)
  }
}

func hasFloatingPointOperands(_ assembly: String, target: String) -> Bool {
  // Match operands only: a hex instruction address such as `d0:` is not an FP register.
  let operands = assembly.split(separator: "\n").compactMap { line -> String? in
    guard line.range(of: #"^\s*[0-9a-f]+:\s"#, options: .regularExpression) != nil,
      let colon = line.firstIndex(of: ":")
    else { return nil }
    return String(line[line.index(after: colon)...].split(separator: "<", maxSplits: 1)[0])
  }.joined(separator: "\n")
  let forbidden =
    target.hasPrefix("x86")
    ? #"%(?:xmm|ymm|zmm|mm)[0-9]+|%st(?:\(|\b)"# : #"\b(?:v[0-9]+|[bhsdqzp][0-9]+)\b"#
  return operands.range(of: forbidden, options: .regularExpression) != nil
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
  guard
    ProcessInfo.processInfo.environment["GUEST_QEMU_BIN"] == nil
      || ProcessInfo.processInfo.environment["KERNEL_LLVM_BIN"] != nil
  else { throw CheckFailure.refused("GUEST_QEMU_BIN requires KERNEL_LLVM_BIN") }
  try files.createDirectory(at: scratch, withIntermediateDirectories: true)

  func run(
    _ name: String, executable: URL, arguments: [String], expectedError: String? = nil,
    expectedTrap: String? = nil,
    expectedOutput: String? = nil, expectedDiagnostic: String? = nil, timeoutSeconds: Int = 60
  )
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
    let end = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
    var oversized = false
    while child.isRunning && ContinuousClock.now < end {
      let size = try files.attributesOfItem(atPath: log.path)[.size] as? NSNumber
      if let size, size.intValue > 262_144 {
        oversized = true
        break
      }
      Thread.sleep(forTimeInterval: 0.02)
    }
    if child.isRunning {
      child.terminate()
      let cleanup = ContinuousClock.now.advanced(by: .seconds(2))
      while child.isRunning && ContinuousClock.now < cleanup { Thread.sleep(forTimeInterval: 0.02) }
      if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
      child.waitUntilExit()
      if oversized { throw CheckFailure.oversizedEvidence }
      throw CheckFailure.deadline
    }
    child.waitUntilExit()
    let size = try files.attributesOfItem(atPath: log.path)[.size] as? NSNumber
    guard let size, size.intValue <= 262_144 else { throw CheckFailure.oversizedEvidence }
    if let expectedTrap {
      let text = try String(contentsOf: log, encoding: .utf8)
      guard child.terminationReason == .uncaughtSignal,
        child.terminationStatus == SIGILL || child.terminationStatus == SIGTRAP,
        text.contains(expectedTrap)
      else { throw CheckFailure.refused(name + ": " + text) }
      print("PASS \(name): expected checked RAM-copy trap")
      return
    }
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
    if let expectedOutput {
      var text = String(decoding: try Data(contentsOf: log), as: UTF8.self)
      if let expectedDiagnostic {
        guard text.components(separatedBy: expectedDiagnostic).count == 2 else {
          throw CheckFailure.refused(name + ": expected platform diagnostic missing/duplicated")
        }
        text = text.replacingOccurrences(of: expectedDiagnostic, with: "")
        print("QUALIFIED \(name): raw platform diagnostic retained; physical reclaim unverified")
      }
      guard text == expectedOutput else { throw CheckFailure.refused(name + ": " + text) }
    }
    print("PASS \(name)")
  }

  let common = [
    "-swift-version", "6", "-O", "-wmo", "-parse-as-library", "-strict-memory-safety",
    "-warnings-as-errors", "-module-cache-path", scratch.appendingPathComponent("modules").path,
  ]
  try run("CompilerVersion", executable: compiler, arguments: ["--version"])
  for (instruction, target, expected) in [
    ("d0: ldr x0, [x1]", "aarch64", false),
    ("10: ld1 {v0.s}[1], [x0]", "aarch64", true),
    ("10: fmov x0, v0.d[1]", "aarch64", true),
    ("10: mov v0, v1", "aarch64", true),
    ("10: fmov d0, x0", "aarch64", true),
    ("10: movq %rax, %rbx", "x86", false),
    ("10: movq %rax, %xmm0", "x86", true),
  ] {
    guard hasFloatingPointOperands(instruction, target: target) == expected else {
      throw CheckFailure.refused("Operand scanner control: " + instruction)
    }
  }
  print("PASS OperandScannerControls")
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

  let typedImage = scratch.appendingPathComponent("EmbeddedTypedProbe")
  try run(
    "EmbeddedTyped", executable: compiler,
    arguments: host + embedded + lifetimes + ["-no-allocations", "-D", "BOUNDEDMEMORY_STANDALONE"]
      + [
        arenaSources[0],
        root.appendingPathComponent("Sources/BoundedMemory/TypedAllocation.swift").path,
        root.appendingPathComponent("Examples/EmbeddedTypedProbe/main.swift").path,
        "-o", typedImage.path,
      ])
  try run("TypedExecution", executable: typedImage, arguments: [])

  let fillImage = scratch.appendingPathComponent("FillProbe")
  try run(
    "EmbeddedFill", executable: compiler,
    arguments: host + embedded + [
      "-no-allocations",
      root.appendingPathComponent("Examples/FreestandingGuest/MemoryFill.swift").path,
      root.appendingPathComponent("Examples/FillProbe/main.swift").path,
      "-o", fillImage.path,
    ])
  try run("FillExecution", executable: fillImage, arguments: [])
  let copyImage = scratch.appendingPathComponent("CopyProbe")
  try run(
    "EmbeddedCopy", executable: compiler,
    arguments: host + embedded + ["-no-allocations"] + [
      root.appendingPathComponent("Examples/FreestandingGuest/MemoryCopy.swift").path,
      root.appendingPathComponent("Examples/CopyProbe/main.swift").path,
      "-o", copyImage.path,
    ])
  try run("CopyExecution", executable: copyImage, arguments: [])
  for (definition, reason) in [
    ("COPY_NIL", "Invalid RAM copy extent"),
    ("COPY_COUNT", "Invalid RAM copy extent"),
    ("COPY_OVERFLOW", "RAM copy address overflow"),
    ("COPY_OVERLAP", "Overlapping RAM copy extents"),
  ] {
    let refusal = scratch.appendingPathComponent(definition)
    try run(
      definition + "Build", executable: compiler,
      arguments: host.map { $0 == "-O" ? "-Onone" : $0 }
        + ["-enable-experimental-feature", "Volatile", "-D", definition] + [
          root.appendingPathComponent("Examples/FreestandingGuest/MemoryCopy.swift").path,
          root.appendingPathComponent("Examples/CopyProbe/Refusal.swift").path,
          "-o", refusal.path,
        ])
    try run(definition + "Execution", executable: refusal, arguments: [], expectedTrap: reason)
  }

  let frameImage = scratch.appendingPathComponent("FrameProbe")
  let frameSources = [
    root.appendingPathComponent("Sources/BoundedMemory/FrameLedger.swift").path,
    root.appendingPathComponent("Examples/FrameTrace/FrameTrace.swift").path,
  ]
  try run(
    "EmbeddedFrames", executable: compiler,
    arguments: host + embedded + lifetimes + ["-no-allocations"] + frameSources + [
      root.appendingPathComponent("Examples/FrameProbe/main.swift").path,
      "-o", frameImage.path,
    ])
  try run("FrameExecution", executable: frameImage, arguments: [])

  #if canImport(Darwin)
    let benchmark = scratch.appendingPathComponent("FrameBenchmark")
    try run(
      "EmbeddedFrameBenchmark", executable: compiler,
      arguments: host + embedded + lifetimes + ["-no-allocations"] + frameSources + [
        root.appendingPathComponent("Examples/FrameBenchmark/main.swift").path,
        "-o", benchmark.path,
      ])
    try run("FrameBenchmarkExecution", executable: benchmark, arguments: [])
    let measurement = try String(
      contentsOf: scratch.appendingPathComponent("FrameBenchmarkExecution.log"), encoding: .utf8
    ).split(whereSeparator: \.isNewline).compactMap { UInt64($0) }
    guard measurement.count == 4, measurement[0] > 0,
      measurement[0] <= measurement[1], measurement[1] <= measurement[2],
      measurement[3] == 65_472_000
    else { throw CheckFailure.refused("Frame benchmark observation") }
  #endif

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
    for name in ["opt", "llc", "llvm-nm", "llvm-objdump", "llvm-readelf"] {
      let tool = llvm.appendingPathComponent(name)
      guard files.isExecutableFile(atPath: tool.path) else {
        throw CheckFailure.refused("Missing requested LLVM tool: " + name)
      }
      try run("Version-" + name, executable: tool, arguments: ["--version"])
    }
    func writeProfile(_ input: URL, output: URL, target: String) throws {
      // Per-function attributes override llc defaults; preserve all stack protection attributes.
      let features =
        target.hasPrefix("x86")
        ? "-mmx,-sse,-sse2,-sse3,-ssse3,-sse4.1,-sse4.2,-avx,-avx2,-avx512f,-x87,+soft-float"
        : "+strict-align,-fp-armv8,-neon,-sve,-sve2,-sme,-sme2"
      let featurePattern = try NSRegularExpression(pattern: #""target-features"="[^"]*""#)
      let text = try String(contentsOf: input, encoding: .utf8)
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
      try profiled.write(to: output, atomically: true, encoding: .utf8)
    }

    let traces = [
      (
        "Arena", "arena_trace",
        [
          arenaSources[0],
          root.appendingPathComponent("Examples/ArenaTrace/ArenaTrace.swift").path,
        ]
      ),
      (
        "TypedArena", "typed_arena_trace",
        [
          arenaSources[0],
          root.appendingPathComponent("Sources/BoundedMemory/TypedAllocation.swift").path,
          root.appendingPathComponent("Examples/TypedTrace/TypedTrace.swift").path,
        ]
      ),
      ("Frames", "frame_trace", frameSources),
    ]
    for (kind, entry, sources) in traces {
      for target in ["aarch64-none-none-elf", "x86_64-unknown-none-elf"] {
        let prefix = kind + "-" + target
        let original = scratch.appendingPathComponent(prefix + ".ll")
        try run(
          prefix, executable: compiler,
          arguments: common + embedded + lifetimes + [
            "-no-allocations", "-target", target, "-emit-ir",
          ] + sources + ["-o", original.path])
        let reachable = scratch.appendingPathComponent(prefix + "-reachable.ll")
        try run(
          prefix + "-Reachable", executable: llvm.appendingPathComponent("opt"),
          arguments: [
            "-verify-each", "-passes=internalize<preserve-gv=" + entry + ">,globaldce", "-S",
            original.path, "-o", reachable.path,
          ])
        let kernelIR = scratch.appendingPathComponent(prefix + "-profile.ll")
        try writeProfile(reachable, output: kernelIR, target: target)
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
        // Retain compiler stack protection and zero restoration; audit this exact PAL boundary.
        let allowedImports: Set<String> =
          kind == "Arena"
          ? []
          : kind == "Frames"
            ? ["memcpy", "memset", "__stack_chk_fail", "__stack_chk_guard"]
            : ["memset", "__stack_chk_fail", "__stack_chk_guard"]
        let importedSymbols = imports.split(separator: "\n").compactMap {
          $0.split(separator: " ").last.map(String.init)
        }
        guard Set(importedSymbols).isSubset(of: allowedImports) else {
          throw CheckFailure.refused("Object imports: " + imports)
        }
        try run(
          prefix + "-Assembly", executable: llvm.appendingPathComponent("llvm-objdump"),
          arguments: ["-d", "--no-show-raw-insn", object.path])
        let assembly = try String(
          contentsOf: scratch.appendingPathComponent(prefix + "-Assembly.log"),
          encoding: .utf8)
        guard !hasFloatingPointOperands(assembly, target: target) else {
          throw CheckFailure.refused("Floating-point/vector register in " + target)
        }
        print("PASS \(prefix): whole object imports \(importedSymbols); no FP/vector registers")

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
    if let qemuPath = ProcessInfo.processInfo.environment["GUEST_QEMU_BIN"] {
      let qemu = URL(fileURLWithPath: qemuPath).standardizedFileURL
      let linker = compiler.deletingLastPathComponent().appendingPathComponent("ld.lld")
      let clang = compiler.deletingLastPathComponent().appendingPathComponent("clang")
      for tool in [qemu, linker, clang] {
        guard files.isExecutableFile(atPath: tool.path) else {
          throw CheckFailure.refused("Missing requested guest tool: " + tool.path)
        }
      }
      try run("QEMUVersion", executable: qemu, arguments: ["--version"])
      try run("LinkerVersion", executable: linker, arguments: ["--version"])
      try run("ClangVersion", executable: clang, arguments: ["--version"])
      let guest = root.appendingPathComponent("Examples/FreestandingGuest")
      let boot = scratch.appendingPathComponent("GuestBoot.o")
      try run(
        "GuestBoot", executable: clang,
        arguments: [
          "--target=aarch64-none-elf", "-c",
          guest.appendingPathComponent("boot.S").path, "-o", boot.path,
        ])
      let sources =
        [
          arenaSources[0],
          root.appendingPathComponent("Sources/BoundedMemory/TypedAllocation.swift").path,
          root.appendingPathComponent("Sources/BoundedMemory/FrameLedger.swift").path,
        ]
        + [
          "Guest.swift", "MemoryFill.swift", "MemoryCopy.swift", "Platform.swift", "Frames.swift",
          "TimerIRQ.swift", "VirtioMMIO.swift", "VirtioDMA.swift", "Balloon.swift",
        ]
        .map {
          guest.appendingPathComponent($0).path
        }
      for (mode, definition, marker) in [
        ("Success", "GUEST_BUILD", "IRQ_PASS\nDMA_PASS\nBALLOON_INFLATED\nBALLOON_PASS\nGUEST_PASS\n"),
        ("Guard", "GUEST_GUARD_FAILURE", "STACK_FAIL\n"),
        ("IRQTimeout", "GUEST_IRQ_MASK", "IRQ_TIMEOUT\n"),
        ("DMAAbsent", "GUEST_DMA_ABSENT", "IRQ_PASS\nDMA_MISSING\n"),
        ("DMAUnpublished", "GUEST_DMA_NO_PUBLISH", "IRQ_PASS\nDMA_TIMEOUT\n"),
        ("BalloonAbsent", "GUEST_BALLOON_ABSENT", "IRQ_PASS\nDMA_PASS\nBALLOON_MISSING\n"),
        ("BalloonNoDeflate", "GUEST_BALLOON_NO_DEFLATE", "IRQ_PASS\nDMA_PASS\nBALLOON_INFLATED\nBALLOON_DEFLATE_TIMEOUT\n"),
        ("Memory", "GUEST_MEMORY_FAILURE", "IRQ_PASS\nDMA_PASS\nBALLOON_INFLATED\nBALLOON_PASS\nMEMORY_FAIL\n"),
        ("Frames", "GUEST_FRAME_FAILURE", "IRQ_PASS\nFRAME_FAIL\n"),
        ("Trap", "GUEST_TRAP_FAILURE", "IRQ_PASS\nDMA_PASS\nBALLOON_INFLATED\nBALLOON_PASS\nBRK_PASS\n"),
        ("TrapOther", "GUEST_TRAP_OTHER", "IRQ_PASS\nDMA_PASS\nBALLOON_INFLATED\nBALLOON_PASS\nTRAP\n"),
      ] {
        let name = "Guest" + mode
        let original = scratch.appendingPathComponent(name + ".ll")
        try run(
          name + "IR", executable: compiler,
          arguments: common + embedded + lifetimes + [
            "-no-allocations",
            "-target", "aarch64-none-none-elf", "-I", guest.path,
            "-D", "GUEST_BUILD", "-D", definition, "-emit-ir",
          ]
            + sources + ["-o", original.path])
        let reachable = scratch.appendingPathComponent(name + "-live.ll")
        let entries = [
          "guest_main", "guest_trap", "memset", "memcpy", "__stack_chk_guard", "__stack_chk_fail",
          "guard_probe", "guest_irq",
        ]
        let preserved = entries.map { "preserve-gv=" + $0 }.joined(separator: ";")
        try run(
          name + "Reachable", executable: llvm.appendingPathComponent("opt"),
          arguments: [
            "-verify-each", "-passes=internalize<" + preserved + ">,globaldce",
            "-S", original.path, "-o", reachable.path,
          ])
        let profile = scratch.appendingPathComponent(name + "-profile.ll")
        try writeProfile(reachable, output: profile, target: "aarch64-none-none-elf")
        let object = scratch.appendingPathComponent(name + ".o")
        try run(
          name + "Object", executable: llvm.appendingPathComponent("llc"),
          arguments: ["-filetype=obj", "-code-model=small", profile.path, "-o", object.path])
        let image = scratch.appendingPathComponent(name + ".elf")
        try run(
          name + "Link", executable: linker,
          arguments: [
            "--gc-sections", "--orphan-handling=error", "-z", "noexecstack",
            "-z", "max-page-size=4096", "-T", guest.appendingPathComponent("link.ld").path,
            boot.path, object.path, "-o", image.path,
          ])
        try run(
          name + "Imports", executable: llvm.appendingPathComponent("llvm-nm"),
          arguments: ["--undefined-only", image.path])
        guard
          try String(
            contentsOf: scratch.appendingPathComponent(name + "Imports.log"),
            encoding: .utf8
          ).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw CheckFailure.refused("Final guest has undefined symbols") }
        try run(
          name + "Headers", executable: llvm.appendingPathComponent("llvm-readelf"),
          arguments: [
            "--file-header", "--program-headers", "--section-headers", "--relocations",
            "--dynamic", image.path,
          ])
        try auditGuestELF(image)
        if mode == "Success" { try checkELFRefusals(image, scratch: scratch) }
        try run(
          name + "Assembly", executable: llvm.appendingPathComponent("llvm-objdump"),
          arguments: ["-d", "--no-show-raw-insn", image.path])
        let assembly = try String(
          contentsOf: scratch.appendingPathComponent(name + "Assembly.log"),
          encoding: .utf8)
        guard !hasFloatingPointOperands(assembly, target: "aarch64")
        else { throw CheckFailure.refused("Guest FP/SIMD") }
        try run(
          name + "Execution", executable: qemu,
          arguments: [
            "-machine", "virt-10.2,secure=off,virtualization=off,gic-version=2", "-accel",
            "tcg,thread=single", "-cpu", "cortex-a72", "-m", "64M", "-smp", "1",
            "-nic", "none", "-display", "none", "-nodefaults", "-monitor", "none",
            "-serial", "stdio", "-no-reboot", "-kernel", image.path,
          ] + (mode == "DMAAbsent" ? [] : [
            "-global", "virtio-mmio.force-legacy=false", "-device", "virtio-rng-device",
          ]) + (mode == "BalloonAbsent" ? [] : [
            "-device", "virtio-balloon-device",
          ]),
          expectedOutput: marker,
          expectedDiagnostic: sysconf(Int32(_SC_PAGESIZE)) > 4096
            && ["Success", "Memory", "Trap", "TrapOther", "BalloonNoDeflate"].contains(mode)
            ? "qemu-system-aarch64: warning: Balloon used with backing page size > 4kiB, this may not be reliable\n"
            : nil,
          timeoutSeconds: 15)
      }
    }
  }

  print("Low-level evidence: \(scratch.path)")
}

do { try checkLowLevel() } catch {
  print("Low-level checks refused: \(error)")
  exit(1)
}
