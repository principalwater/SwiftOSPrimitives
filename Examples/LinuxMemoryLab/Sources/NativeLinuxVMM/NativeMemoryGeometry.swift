/// Validated GPA layout; dynamic RAM never overlaps boot RAM or MMIO.
public struct NativeMemoryGeometry: Sendable, Equatable {
  public let bootBytes: UInt64
  public let dynamicBytes: UInt64
  public var maximumBytes: UInt64 { bootBytes + dynamicBytes }

  public init(bootBytes: UInt64, dynamicBytes: UInt64) throws {
    // DTB at120MiB and the optional128..192MiB initrd must fit in immutable boot RAM.
    guard bootBytes >= 256 << 20, bootBytes <= 3 << 30,
      bootBytes % (128 << 20) == 0,
      dynamicBytes >= 128 << 20, dynamicBytes <= 2 << 30,
      dynamicBytes % (128 << 20) == 0
    else { throw NativeFailure.unsupported }
    self.bootBytes = bootBytes
    self.dynamicBytes = dynamicBytes
  }

  public static let qualification = try! NativeMemoryGeometry(
    bootBytes: 1024 << 20, dynamicBytes: 128 << 20)
}
