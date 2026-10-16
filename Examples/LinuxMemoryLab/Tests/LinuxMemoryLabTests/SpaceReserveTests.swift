import Darwin
import Foundation
import Testing

@testable import NativeLinuxVMM

@Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTOS_SPACE_FIXTURE"] != nil))
func sustainedDiskReservesSpaceOnAnIsolatedSmallVolume() throws {
  let path = URL(
    filePath: try #require(ProcessInfo.processInfo.environment["SWIFTOS_SPACE_FIXTURE"]))
  var space = statfs()
  try #require(statfs(path.path, &space) == 0 && space.f_bsize > 0)
  let initialFree = space.f_bavail * UInt64(space.f_bsize)
  try #require(initialFree > (1 << 30) + 65536 && initialFree < (1536 << 20))
  let descriptor = open(path.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
  try #require(descriptor >= 0)
  defer { _ = Darwin.close(descriptor) }
  let device = try BlockDevice(path: path.path, executionPolicy: .sustained)
  defer {
    do { try device.close() } catch { Issue.record("Disk close: \(error)", severity: .error) }
  }
  let fixture = RingFixture(byteCount: 131072)
  fixture.store(UInt32(1), 1024)
  memset(fixture.bytes.advanced(by: 4096), 0x5a, 65536)
  let buffers = [
    GuestBuffer(address: 1024, size: 16, writable: false),
    GuestBuffer(address: 4096, size: 65536, writable: false),
    GuestBuffer(address: 3072, size: 1, writable: true),
  ]
  var admitted = 0
  var refused = false
  for index in 0..<8192 {
    fixture.store(UInt64(index * 128), 1032)
    do {
      #expect(try device.process(buffers, memory: fixture.memory) == 1)
      admitted += 1
    } catch DeviceFailure.request {
      refused = true
      break
    }
  }
  try #require(refused && admitted > 0 && admitted < 8192)
  #expect(device.written == UInt64(admitted) * 65536)
  var actual = [UInt8](repeating: 0, count: 65536)
  #expect(pread(descriptor, &actual, actual.count, off_t((admitted - 1) * 65536)) == 65536)
  #expect(actual.allSatisfy { $0 == 0x5a })
  #expect(pread(descriptor, &actual, actual.count, off_t(admitted * 65536)) == 65536)
  #expect(actual.allSatisfy { $0 == 0 })
  try #require(fstatfs(descriptor, &space) == 0)
  let remaining = space.f_bavail * UInt64(space.f_bsize)
  // APFS metadata consumes blocks too; this is an admission reserve, not a global free-space lock.
  #expect(remaining >= (1020 << 20) && remaining < initialFree)
  print(
    "SPACE_RESERVE_CHECK admitted=\(device.written) initialFree=\(initialFree) remaining=\(remaining)"
  )
}
