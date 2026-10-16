import Darwin
import Foundation
import Testing

@testable import NativeLinuxVMM

@Test func sustainedConsoleRotatesOwnedFileAndKeepsRecentLinesWithFramingFence() throws {
  let path = URL(filePath: try #require(ProcessInfo.processInfo.environment["TMPDIR"]))
    .appending(path: UUID().uuidString + ".log")
  let descriptor = open(path.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
  try #require(descriptor >= 0)
  let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
  defer {
    _ = Darwin.close(descriptor)
    _ = unlink(path.path)
  }
  var journal = ConsoleJournal(policy: .sustained)
  var delivered = 0
  func uniqueLine(_ index: Int) -> String {
    let prefix = "\(index):"
    return prefix + String(repeating: "x", count: 1023 - prefix.utf8.count) + "\n"
  }
  for index in 0..<4096 {
    let expected = uniqueLine(index)
    for byte in expected.utf8 {
      if let line = try journal.append(byte, sink: handle) {
        #expect(line == expected)
        delivered += 1
      }
    }
  }
  #expect(delivered == 4096 && journal.retained.count == 65536)
  #expect(journal.retained == Data((4032..<4096).map(uniqueLine).joined().utf8))
  let size = try handle.seekToEnd()
  #expect(size == 1_048_576)
  #expect(try Data(contentsOf: path) == Data((3072..<4096).map(uniqueLine).joined().utf8))
  for _ in 0..<8192 { _ = try journal.append(65, sink: handle) }
  #expect(journal.retained.suffix(8192) == Data(repeating: 65, count: 8192))
  #expect(journal.retained.count == 65536)
  #expect(throws: Failure.self) { _ = try journal.append(10, sink: handle) }
  var finite = ConsoleJournal(policy: .qualification)
  for _ in 0..<2_097_152 { _ = try finite.append(10, sink: nil) }
  #expect(throws: Failure.self) { _ = try finite.append(10, sink: nil) }
}

@Test func failedConsoleSinkKeepsFinalDiagnosticAndRefusesFurtherWrites() throws {
  let path = URL(filePath: try #require(ProcessInfo.processInfo.environment["TMPDIR"]))
    .appending(path: UUID().uuidString + ".log")
  try Data().write(to: path, options: .withoutOverwriting)
  defer { _ = unlink(path.path) }
  let handle = try FileHandle(forReadingFrom: path)
  defer { try? handle.close() }
  var journal = ConsoleJournal(policy: .sustained)
  for byte in "failure".utf8 { _ = try journal.append(byte, sink: handle) }
  #expect(throws: (any Error).self) { _ = try journal.append(10, sink: handle) }
  #expect(journal.retained == Data("failure\n".utf8))
  do {
    _ = try journal.append(65, sink: nil)
    Issue.record("A failed journal accepted another byte", severity: .error)
  } catch Failure.boundary {
  } catch {
    Issue.record("Unexpected journal error: \(error)", severity: .error)
  }
  #expect(journal.retained == Data("failure\n".utf8))
}

@Test(.serialized, arguments: [NativeExecutionPolicy.qualification, .sustained])
func realDiskWritesHonorQualificationQuotaWithoutImposingServiceLifetimeQuota(
  _ policy: NativeExecutionPolicy
) throws {
  let root = URL(filePath: try #require(ProcessInfo.processInfo.environment["TMPDIR"]))
    .appending(path: UUID().uuidString)
  let artifacts = root.appending(path: "artifacts")
  let marker = root.appending(path: "OWNER.json")
  let path = artifacts.appending(path: "clickhouse-run-write-quota.ext4")
  try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
  defer {
    _ = unlink(path.path)
    _ = unlink(marker.path)
    _ = rmdir(artifacts.path)
    _ = rmdir(root.path)
  }
  try JSONSerialization.data(withJSONObject: [
    "root": root.path, "uid": Int(getuid()), "purpose": "isolated-container-managed-G23",
  ]).write(to: marker, options: .withoutOverwriting)
  let descriptor = open(path.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
  try #require(descriptor >= 0)
  defer { _ = Darwin.close(descriptor) }
  try #require(ftruncate(descriptor, 8 << 30) == 0)
  let device =
    try policy == .qualification
    ? BlockDevice(path: path.path) : BlockDevice(path: path.path, executionPolicy: policy)
  defer {
    do { try device.close() } catch { Issue.record("Disk close: \(error)", severity: .error) }
  }
  let fixture = RingFixture(byteCount: 131072)
  fixture.store(UInt32(1), 1024)
  fixture.store(UInt64(0), 1032)
  memset(fixture.bytes.advanced(by: 4096), 0x5a, 65536)
  let buffers = [
    GuestBuffer(address: 1024, size: 16, writable: false),
    GuestBuffer(address: 4096, size: 65536, writable: false),
    GuestBuffer(address: 3072, size: 1, writable: true),
  ]
  for _ in 0..<8192 {
    #expect(try device.process(buffers, memory: fixture.memory) == 1)
  }
  #expect(device.written == 536_870_912)
  memset(fixture.bytes.advanced(by: 4096), 0xa5, 65536)
  if policy == .qualification {
    #expect(throws: DeviceFailure.self) { _ = try device.process(buffers, memory: fixture.memory) }
    #expect(device.written == 536_870_912)
  } else {
    #expect(try device.process(buffers, memory: fixture.memory) == 1)
    #expect(device.written == 536_936_448)
  }
  var actual = [UInt8](repeating: 0, count: 65536)
  #expect(pread(descriptor, &actual, actual.count, 0) == 65536)
  #expect(actual.allSatisfy { $0 == (policy == .qualification ? 0x5a : 0xa5) })
}
