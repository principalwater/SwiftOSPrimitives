import PageMemory

#if os(Linux)
  import MemoryFaultABI
  #if canImport(Musl)
    import Musl
  #else
    import Glibc
  #endif

  // Serialized, single-process linker fixture. No exported wrapper enters package products.
  nonisolated(unsafe) private var rejectMap = false
  nonisolated(unsafe) private var captureMap = false
  nonisolated(unsafe) private var trackedAddress: UInt = 0
  nonisolated(unsafe) private var rejectUnmap = false
  nonisolated(unsafe) private var unmapAttempts = 0
  nonisolated(unsafe) private var destructions = 0
  nonisolated(unsafe) private var sawDestructionBeforeUnmap = false
  nonisolated(unsafe) private var returnZeroMap = false
  nonisolated(unsafe) private var trackZeroUnmap = false

  @c(__wrap_mmap)
  @unsafe public func wrappedMap(
    _ address: UnsafeMutableRawPointer?, _ length: Int, _ protection: Int32,
    _ flags: Int32, _ descriptor: Int32, _ offset: off_t
  ) -> UnsafeMutableRawPointer? {
    if unsafe returnZeroMap {
      unsafe returnZeroMap = false
      return nil
    }
    if unsafe rejectMap {
      unsafe rejectMap = false
      errno = ENOMEM
      return unsafe UnsafeMutableRawPointer(bitPattern: -1)
    }
    let result = unsafe __real_mmap(address, length, protection, flags, descriptor, offset)
    if unsafe captureMap {
      unsafe captureMap = false
      unsafe trackedAddress = UInt(bitPattern: result)
    }
    return unsafe result
  }

  @c(__wrap_munmap)
  @unsafe public func wrappedUnmap(_ address: UnsafeMutableRawPointer?, _ length: Int) -> Int32 {
    if unsafe (UInt(bitPattern: address) == trackedAddress && trackedAddress != 0)
      || (address == nil && trackZeroUnmap)
    {
      unsafe unmapAttempts += 1
      unsafe sawDestructionBeforeUnmap = destructions == 1
      if unsafe rejectUnmap {
        unsafe rejectUnmap = false
        errno = ENOMEM
        return -1
      }
    }
    return unsafe __real_munmap(address, length)
  }

  private struct Token: ~Copyable {
    let value: Int
    deinit { unsafe destructions += 1 }
  }
  private enum Failure: Error { case constructor, contract }

  private func check() throws {
    var factories = 0
    unsafe rejectMap = true
    do {
      _ = try MappedValue<Int>.allocate {
        factories += 1
        return 73
      }
      throw Failure.contract
    } catch MappedValueError<Never>.memory(.systemCall(operation: .map, code: ENOMEM)) {}
    guard factories == 0, unsafe !rejectMap else { throw Failure.contract }

    // Inject an otherwise inaccessible null mapping result; never map the host's zero page.
    unsafe returnZeroMap = true
    unsafe trackZeroUnmap = true
    unsafe rejectUnmap = true
    do {
      _ = try MappedValue<Int>.allocate {
        factories += 1
        return 73
      }
      throw Failure.contract
    } catch MappedValueError<Never>.memory(.systemCall(operation: .unmap, code: ENOMEM)) {}
    guard factories == 0, unsafe unmapAttempts == 2 else { throw Failure.contract }
    unsafe trackZeroUnmap = false
    unsafe unmapAttempts = 0

    unsafe captureMap = true
    do {
      _ = try MappedValue<Int>.allocate { () throws(Failure) -> Int in throw .constructor }
      throw Failure.contract
    } catch MappedValueError<Failure>.factory(.constructor) {}
    guard unsafe unmapAttempts == 1 else { throw Failure.contract }
    unsafe unmapAttempts = 0
    unsafe captureMap = true
    var owner = try MappedValue.allocate { Token(value: 73) }
    guard try owner.withValue({ $0[0].value == 73 }) else { throw Failure.contract }
    unsafe rejectUnmap = true
    do {
      try owner.release()
      throw Failure.contract
    } catch PageMemoryError.systemCall(operation: .unmap, code: ENOMEM) {}
    guard owner.isDestroyed && !owner.isReleased, unsafe destructions == 1 && unmapAttempts == 1,
      unsafe sawDestructionBeforeUnmap
    else { throw Failure.contract }
    do {
      _ = try owner.withValue { $0.count }
      throw Failure.contract
    } catch PageMemoryError.unavailable {}
    try owner.release()
    try owner.release()
    guard owner.isReleased, unsafe destructions == 1 && unmapAttempts == 2 else {
      throw Failure.contract
    }
    unsafe trackedAddress = 0
    print(
      "{\"pass\":true,\"map_failure\":true,\"zero_address_cleanup\":true,\"factory_unwind\":true,"
        + "\"unmap_failure\":true,\"unmap_attempts\":2,\"destructions\":1}")
  }

  do { try check() } catch {
    print("Memory fault probe failed: \(error)")
    exit(1)
  }
#else
  print("Memory fault ABI probe requires Linux and its linker --wrap boundary.")
#endif
