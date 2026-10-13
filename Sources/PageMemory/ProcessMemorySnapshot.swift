#if canImport(Darwin)
  import Darwin
#elseif os(Linux) && canImport(Glibc)
  import Glibc
#elseif os(Linux) && canImport(Musl)
  import Musl
#endif

/// A failed self-memory observation; Mach and POSIX codes retain their native operation.
public enum MemoryObservationError: Error, Equatable, Sendable {
  case systemCall(operation: Operation, code: Int32)
  case malformedCounters
  public enum Operation: Sendable { case taskInfo, selfMemory, pageSize }
}

/// Native counters for the calling process, separate from owned mappings and allocator advice.
public struct ProcessMemorySnapshot: Equatable, Sendable {
  public let residentBytes: UInt64
  /// Darwin's accounting ledger; unknown on Linux. This is not a physical-release delta.
  public let physicalFootprintBytes: UInt64?

  /// Reads self counters with bounded scratch storage and no background sampling task.
  public static func capture() throws(MemoryObservationError) -> ProcessMemorySnapshot {
    #if canImport(Darwin)
      var info = task_vm_info_data_t()
      let capacity = MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
      var count = mach_msg_type_number_t(capacity)
      let result = withUnsafeMutablePointer(to: &info) { pointer in
        unsafe pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) { words in
          unsafe task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), words, &count)
        }
      }
      guard result == KERN_SUCCESS else { throw .systemCall(operation: .taskInfo, code: result) }
      guard let residentOffset = MemoryLayout<task_vm_info_data_t>.offset(of: \.resident_size),
        let footprintOffset = MemoryLayout<task_vm_info_data_t>.offset(of: \.phys_footprint)
      else { throw .malformedCounters }
      let returnedBytes = Int(count) * MemoryLayout<integer_t>.size
      guard returnedBytes >= residentOffset + MemoryLayout<mach_vm_size_t>.size else {
        throw .malformedCounters
      }
      let footprintEnd = footprintOffset + MemoryLayout<mach_vm_size_t>.size
      return ProcessMemorySnapshot(
        residentBytes: info.resident_size,
        physicalFootprintBytes: returnedBytes >= footprintEnd ? info.phys_footprint : nil)
    #else
      let fd = unsafe open("/proc/self/statm", O_RDONLY | O_CLOEXEC)
      guard fd >= 0 else { throw .systemCall(operation: .selfMemory, code: errno) }
      defer { _ = close(fd) }
      var buffer = InlineArray<256, UInt8>(repeating: 0)
      var used = 0
      var interruptions = 0
      while used < 256 {
        let amount = withUnsafeMutablePointer(to: &buffer) { pointer in
          unsafe pointer.withMemoryRebound(to: UInt8.self, capacity: 256) { bytes in
            unsafe read(fd, bytes.advanced(by: used), 256 - used)
          }
        }
        if amount == 0 { break }
        if amount < 0 {
          if errno == EINTR && interruptions < 8 {
            interruptions += 1
            continue
          }
          throw .systemCall(operation: .selfMemory, code: errno)
        }
        used += amount
      }
      guard used < 256 else { throw .malformedCounters }
      var cursor = 0
      func number() -> UInt64? {
        while cursor < used && (buffer[cursor] == 32 || buffer[cursor] == 10) { cursor += 1 }
        let start = cursor
        var value: UInt64 = 0
        while cursor < used && (48...57).contains(buffer[cursor]) {
          let digit = UInt64(buffer[cursor] - 48)
          guard value <= (UInt64.max - digit) / 10 else { return nil }
          value = value * 10 + digit
          cursor += 1
        }
        guard cursor > start,
          cursor == used || buffer[cursor] == 32 || buffer[cursor] == 10
        else { return nil }
        return value
      }
      guard number() != nil, let pages = number() else { throw .malformedCounters }
      let pageSize = sysconf(Int32(_SC_PAGESIZE))
      guard pageSize > 0 else { throw .systemCall(operation: .pageSize, code: errno) }
      guard pages <= UInt64.max / UInt64(pageSize) else { throw .malformedCounters }
      return ProcessMemorySnapshot(
        residentBytes: pages * UInt64(pageSize), physicalFootprintBytes: nil)
    #endif
  }
}
