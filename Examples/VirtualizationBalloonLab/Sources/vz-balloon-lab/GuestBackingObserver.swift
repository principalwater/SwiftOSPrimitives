import Darwin
import Foundation
import Virtualization

/// SDK27 diagnostic only: no byte reads/writes, purge, or page-return authority.
@MainActor
final class GuestBackingObserver: NSObject,
  @preconcurrency VZCustomVirtioDeviceConfigurationDelegate
{
  enum Failure: Error {
    case state, missingDevice, unavailableRange, geometry
    case native(Int32)
    case incomplete
  }
  private var device: VZCustomVirtioDevice?
  private var configured = false

  func configure(_ config: VZVirtualMachineConfiguration) throws {
    guard !configured, config.customVirtioDevices.isEmpty else { throw Failure.state }
    configured = true
    let custom = VZCustomVirtioDeviceConfiguration()
    // Unassigned diagnostic ID; no guest driver or queue operation is required.
    custom.deviceID = 63
    custom.pciClassID = 0xff
    custom.pciSubclassID = 0
    custom.virtioQueueCount = 1
    custom.provider = VZCustomVirtioDeviceDelegateProvider(deviceQueue: .main, delegate: self)
    config.customVirtioDevices = [custom]
  }

  func customVirtioConfiguration(
    _ deviceConfiguration: VZCustomVirtioDeviceConfiguration,
    didCreateDevice device: VZCustomVirtioDevice
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    precondition(self.device == nil)
    self.device = device
  }

  func retire() { device = nil }

  func snapshot(at physicalAddress: UInt64, bytes: Int) throws -> [String: UInt64] {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let device else { throw Failure.missingDevice }
    let pageSize = Int(sysconf(Int32(_SC_PAGESIZE)))
    func setting(_ name: String) throws -> Int32 {
      var value: Int32 = 0
      var count = MemoryLayout<Int32>.size
      guard sysctlbyname(name, &value, &count, nil, 0) == 0 else {
        throw Failure.native(errno)
      }
      guard count == MemoryLayout<Int32>.size else { throw Failure.incomplete }
      return value
    }
    let mode = try setting("vm.self_region_page_size")
    guard pageSize > 0, bytes > 0, bytes <= 512 << 20, bytes % pageSize == 0,
      mode == 1 || mode == pageSize, try setting("vm.self_region_footprint") == 0
    else { throw Failure.geometry }
    // Each observation drops its mapping before returning: it retains the VM's DRAM object.
    return try autoreleasepool {
      guard
        let mapping = device.guestMemoryMapping(
          atPhysicalAddress: physicalAddress, length: bytes), mapping.length == bytes,
        mapping.physicalAddress == physicalAddress,
        UInt(bitPattern: mapping.mutableBytes) % UInt(pageSize) == 0
      else { throw Failure.unavailableRange }
      return try withExtendedLifetime(mapping) {
        try withUnsafeTemporaryAllocation(of: integer_t.self, capacity: 256) { scratch in
          guard let base = scratch.baseAddress else { throw Failure.incomplete }
          var present: UInt64 = 0
          var pagedOut: UInt64 = 0
          var reusable: UInt64 = 0
          var offset = 0
          while offset < bytes {
            scratch.initialize(repeating: .min)
            let length = min(bytes - offset, 255 * pageSize)
            let expected = length / pageSize
            var count = mach_vm_size_t(expected + 1)
            let code = mach_vm_page_range_query(
              mach_task_self_, UInt64(UInt(bitPattern: mapping.mutableBytes.advanced(by: offset))),
              UInt64(length), UInt64(UInt(bitPattern: base)), &count)
            guard code == KERN_SUCCESS else { throw Failure.native(code) }
            guard count == expected else { throw Failure.incomplete }
            for index in 0..<expected {
              let flags = scratch[index]
              guard flags != .min else { throw Failure.incomplete }
              if flags & VM_PAGE_QUERY_PAGE_PRESENT != 0 { present += 1 }
              if flags & VM_PAGE_QUERY_PAGE_PAGED_OUT != 0 { pagedOut += 1 }
              if flags & VM_PAGE_QUERY_PAGE_REUSABLE != 0 { reusable += 1 }
            }
            offset += length
          }
          guard try setting("vm.self_region_page_size") == mode,
            try setting("vm.self_region_footprint") == 0
          else { throw Failure.geometry }
          return [
            "hostPageBytes": UInt64(pageSize), "guestPhysicalBase": mapping.physicalAddress,
            "mappedBytes": UInt64(bytes), "presentPages": present,
            "pagedOutPages": pagedOut, "reusablePages": reusable,
          ]
        }
      }
    }
  }
}
