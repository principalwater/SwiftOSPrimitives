import Darwin
import Dispatch
import Foundation
import Hypervisor
import Synchronization

/// Finite lab-only owner check; no diagnostic entry point is added to the product manager.
enum NativeMemoryDeviceCheck {
  private final class Kick: Sendable {
    let running = Atomic(false)
    let error = Atomic<Int32>(0)
    let cpu: hv_vcpu_t
    init(_ cpu: hv_vcpu_t) { self.cpu = cpu }
    func cancelRun() {
      guard running.load(ordering: .acquiring) else { return }
      var id = cpu
      let result = hv_vcpus_exit(&id, 1)
      if result != 0 {
        _ = error.compareExchange(expected: 0, desired: result, ordering: .acquiringAndReleasing)
      }
    }
  }
  private struct Mapping {
    let address: UInt64
    var pointer: UnsafeMutableRawPointer?
    var mapped = false
  }
  static func run(image: String, destination: String, coldProvisioning: Bool = false) throws {
    func require(_ value: Bool, _ label: String) throws {
      guard value else { throw DeviceFailure.observation("cold-check " + label) }
    }
    let fd = open(image, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw Failure.arguments }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? file.close() }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
      info.st_size > 0, info.st_size <= 65536,
      let code = try file.read(upToCount: 65537), code.count == info.st_size
    else { throw Failure.arguments }
    let output = URL(filePath: destination)
    guard output.standardizedFileURL == output, output.resolvingSymlinksInPath() == output else {
      throw Failure.arguments
    }
    try FileManager.default.createDirectory(
      at: output, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    var created = false
    var mappings: [Mapping] = []
    var cpu: hv_vcpu_t?
    var exitInfo: UnsafeMutablePointer<hv_vcpu_exit_t>?
    var kick: Kick?
    let queue = DispatchQueue(label: "native-memory-device-check-kick")
    var timer: DispatchSourceTimer?
    let memory = MemoryDevice(
      held: false, aliasControl: true, coldProvisioning: coldProvisioning)
    let index = 32
    let address = MemoryDevice.base + UInt64(index * MemoryDevice.block)
    let ringAddress: UInt64 = 0x230000
    let reporting = FreePageReportingDevice()
    var published: UInt16 = 0
    var epoch = 0
    var primary = ""
    var cleanup: [String] = []
    var steps: [String] = []
    var initialResidentBytes: UInt64?
    func metadata(_ address: UInt64, _ count: Int) throws -> UnsafeMutableRawPointer {
      guard count >= 0, count <= 65536, address >= ringAddress,
        address - ringAddress <= UInt64(65536 - count), mappings.count == 3,
        let pointer = mappings[2].pointer
      else { throw Failure.boundary }
      return pointer + Int(address - ringAddress)
    }
    func deviceWrite(_ offset: UInt64, _ value: UInt32) throws {
      _ = try reporting.access(
        offset, width: 4, write: value, boot: ringAddress..<(ringAddress + 65536),
        memory: memory, metadata: metadata, quiescence: (true, epoch, 1))
    }
    func report(poison: UInt32 = 0) throws {
      try require(published < .max, "bounded report sequence")
      try deviceWrite(0x10c, poison)
      published += 1
      let ring = try metadata(ringAddress, 65536)
      ring.storeBytes(of: published.littleEndian, toByteOffset: 258, as: UInt16.self)
      try deviceWrite(0x50, 2)
      try require(
        ring.loadUnaligned(fromByteOffset: 514, as: UInt16.self).littleEndian == published,
        "used acknowledgement")
      try require(reporting.transport.interruptStatus == 1, "used interrupt")
      try deviceWrite(0x64, 1)
      try require(reporting.transport.interruptStatus == 0, "interrupt acknowledgement")
    }
    func request(_ kind: UInt16) throws -> Data {
      var bytes = Data(count: 24)
      bytes.withUnsafeMutableBytes {
        $0.storeBytes(of: kind.littleEndian, as: UInt16.self)
        $0.storeBytes(of: address.littleEndian, toByteOffset: 8, as: UInt64.self)
        $0.storeBytes(of: UInt16(1).littleEndian, toByteOffset: 16, as: UInt16.self)
      }
      return try memory.request(bytes, quiescence: (true, epoch, 1))
    }
    func acknowledged(_ kind: UInt16) throws {
      let reply = try request(kind)
      try require(reply.count == 10 && reply.allSatisfy { $0 == 0 }, "request ACK")
    }
    // The tiny guest returns ownership at HVC and never accesses data without a new host command.
    func execute(_ operation: UInt64, pages: UInt64, expected: UInt64 = 0) throws {
      guard let cpu, let kick, let exitInfo else { throw Failure.boundary }
      for (register, value) in [
        (HV_REG_PC, UInt64(0x100000)), (HV_REG_CPSR, 0x3c5), (HV_REG_X0, address),
        (HV_REG_X1, pages), (HV_REG_X2, 0x31a7), (HV_REG_X3, operation),
      ] { try check(hv_vcpu_set_reg(cpu, register, value), "cold-set-register") }
      let deadline = ContinuousClock.now.advanced(by: .seconds(2))
      while ContinuousClock.now < deadline {
        try check(kick.error.load(ordering: .acquiring), "cold-watchdog")
        kick.running.store(true, ordering: .releasing)
        let result = hv_vcpu_run(cpu)
        kick.running.store(false, ordering: .releasing)
        try check(result, "cold-run")
        epoch += 1
        if exitInfo.pointee.reason == HV_EXIT_REASON_CANCELED { continue }
        try require(
          exitInfo.pointee.reason == HV_EXIT_REASON_EXCEPTION
            && exitInfo.pointee.exception.syndrome >> 26 == 0x16, "guest HVC")
        var value: UInt64 = .max
        try check(hv_vcpu_get_reg(cpu, HV_REG_X0, &value), "cold-guest-result")
        try require(value == expected, "guest result \(value), expected \(expected)")
        return
      }
      throw Failure.deadline
    }
    do {
      try check(hv_vm_create(nil), "cold-create")
      created = true
      for address: UInt64 in [0x100000, 0x210000, ringAddress] {
        mappings.append(Mapping(address: address))
        let index = mappings.count - 1
        try check(hv_vm_allocate(&mappings[index].pointer, 65536, 0), "cold-allocate")
        guard let pointer = mappings[index].pointer else { throw Failure.boundary }
        try check(
          mach_vm_inherit(
            mach_task_self_, UInt64(UInt(bitPattern: pointer)), 65536, VM_INHERIT_NONE),
          "cold-inherit-none")
        try check(
          hv_vm_map(pointer, address, 65536, UInt64(HV_MEMORY_READ | HV_MEMORY_WRITE)), "cold-map")
        mappings[index].mapped = true
      }
      let codePointer = mappings[0].pointer!
      code.withUnsafeBytes { codePointer.copyMemory(from: $0.baseAddress!, byteCount: code.count) }
      sys_icache_invalidate(codePointer, code.count)
      try check(
        hv_vm_protect(0x100000, 65536, UInt64(HV_MEMORY_READ | HV_MEMORY_EXEC)), "cold-code-rx")
      try check(
        mach_vm_protect(
          mach_task_self_, UInt64(UInt(bitPattern: codePointer)), 65536, 0, VM_PROT_READ),
        "cold-code-host-ro")
      var nativeCPU: hv_vcpu_t = 0
      try check(hv_vcpu_create(&nativeCPU, &exitInfo, nil), "cold-vcpu-create")
      cpu = nativeCPU
      try check(hv_vcpu_set_sys_reg(nativeCPU, HV_SYS_REG_SP_EL1, 0x220000), "cold-stack")
      try check(hv_vcpu_set_sys_reg(nativeCPU, HV_SYS_REG_CPACR_EL1, 3 << 20), "cold-enable-fp")
      let target = Kick(nativeCPU)
      kick = target
      let watchdog = DispatchSource.makeTimerSource(queue: queue)
      watchdog.setEventHandler { target.cancelRun() }
      watchdog.schedule(deadline: .now() + .milliseconds(2), repeating: .milliseconds(2))
      watchdog.resume()
      timer = watchdog
      let ring = try metadata(ringAddress, 65536)
      ring.storeBytes(of: address.littleEndian, as: UInt64.self)
      ring.storeBytes(of: UInt32(2 << 20).littleEndian, toByteOffset: 8, as: UInt32.self)
      ring.storeBytes(of: UInt16(2).littleEndian, toByteOffset: 12, as: UInt16.self)
      try deviceWrite(0x70, 3)
      try deviceWrite(0x20, (1 << 4) | (1 << 5))
      try deviceWrite(0x24, 1)
      try deviceWrite(0x20, 1)
      try deviceWrite(0x70, 11)
      try deviceWrite(0x30, 2)
      for (offset, value): (UInt64, UInt32) in [
        (0x38, 8), (0x80, UInt32(ringAddress)), (0x90, UInt32(ringAddress + 256)),
        (0xa0, UInt32(ringAddress + 512)),
      ] { try deviceWrite(offset, value) }
      try deviceWrite(0x44, 1)
      try deviceWrite(0x70, 15)
      try acknowledged(0)
      let pageSize = Int(sysconf(Int32(_SC_PAGESIZE)))
      try require(pageSize > 0 && MemoryDevice.block % pageSize == 0, "native page geometry")
      initialResidentBytes = try withUnsafeTemporaryAllocation(
        of: Int8.self, capacity: MemoryDevice.block / pageSize
      ) { pages in
        pages.initialize(repeating: 0)
        guard mincore(memory.extents[index].pointer!, MemoryDevice.block, pages.baseAddress!) == 0
        else { throw DeviceFailure.native(errno) }
        return pages.reduce(UInt64(0)) { $0 + ($1 & 1 != 0 ? UInt64(pageSize) : 0) }
      }
      try require(
        initialResidentBytes == (coldProvisioning ? 0 : UInt64(MemoryDevice.block)),
        "initial plug residency \(initialResidentBytes ?? .max)")
      try execute(0, pages: 512)
      try report()
      try require(memory.recycledBackingBytes == 0 && memory.refusalsTotal == 1, "alias refused")
      try execute(0, pages: 512)
      try memory.releaseAlias()
      try report()
      try require(
        memory.recyclingObservations.last?["hostInitializedBytes"] as? Int
          == (coldProvisioning ? 0 : 2 << 20),
        "first report provenance")
      steps.append("alias refusal restores data, first report preserves initialization provenance")
      try report()
      try require(memory.recyclingObservations.last?["residentBytesObservedBefore"] as? UInt64 == 0,
        "untouched cold report")
      steps.append("untouched cold backing reports again")
      let coldResidentBeforeTouch = memory.recycledColdResidentBytes
      try execute(1, pages: 16)
      try report()
      try require(
        memory.recycledColdResidentBytes - coldResidentBeforeTouch == 65536,
        "guest-touch resident accounting")
      memory.requested = 0
      try acknowledged(1)
      try require(memory.observations.last?["residentBytesObservedBefore"] as? UInt64 == 0,
        "untouched cold unplug")
      try require(memory.observations.last?["hostInitializedBytes"] as? Int == 0,
        "cold unplug provenance")
      steps.append("guest-touched backing reports, untouched replacement unplugs")
      memory.requested = UInt64(MemoryDevice.block)
      try acknowledged(0)
      try report()
      try execute(0, pages: 512)
      try execute(1, pages: 512)
      try execute(2, pages: 512)
      let pointer = memory.extents[index].pointer!
      let word = pointer.load(as: UInt64.self)
      pointer.storeBytes(of: word ^ 1, as: UInt64.self)
      try execute(2, pages: 512, expected: 3)
      pointer.storeBytes(of: word, as: UInt64.self)
      try execute(2, pages: 512)
      let beforePoison = memory.recycledBackingBytes
      try report(poison: 0xa5a5_a5a5)
      try require(memory.recycledBackingBytes == beforePoison, "poison preserves backing")
      try execute(2, pages: 512)
      try report()
      try execute(0, pages: 512)
      try execute(1, pages: 512)
      try execute(2, pages: 512)
      let recycled = memory.recycledBackingBytes
      try memory.quarantine(quiescence: (true, epoch, 1))
      try report()
      try require(memory.recycledBackingBytes == recycled, "quarantine preserves backing")
      try execute(2, pages: 512)
      steps.append("zero/pattern/corruption, poison and quarantine preserve guest data")
      try require(reporting.reports == 8 && published == 8, "wire report count")
    } catch { primary = String(describing: error) }
    kick?.running.store(false, ordering: .releasing)
    timer?.cancel()
    queue.sync {}
    if let cpu {
      let result = hv_vcpu_destroy(cpu)
      if result != 0 { cleanup.append("vcpu-destroy \(result)") }
    }
    do { try memory.close() } catch { cleanup.append("memory-close \(error)") }
    for mapping in mappings.reversed() {
      if mapping.mapped {
        let result = hv_vm_unmap(mapping.address, 65536)
        if result != 0 { cleanup.append("unmap \(result)"); continue }
      }
      if let pointer = mapping.pointer {
        let result = hv_vm_deallocate(pointer, 65536)
        if result != 0 { cleanup.append("deallocate \(result)") }
      }
    }
    if created {
      let result = hv_vm_destroy()
      if result == 0 { created = false } else { cleanup.append("vm-destroy \(result)") }
    }
    let result: [String: Any] = [
      "primaryError": primary, "cleanupErrors": cleanup, "vmDestroyed": !created,
      "coldProvisioningRequested": coldProvisioning,
      "residentBytesAfterInitialPlug": initialResidentBytes.map { $0 as Any } ?? NSNull(),
      "steps": steps, "memoryObservations": memory.observations,
      "recyclingObservations": memory.recyclingObservations, "refusals": memory.refusals,
      "recycledBackingBytes": memory.recycledBackingBytes,
      "recycledResidentBytes": memory.recycledResidentBytes,
      "recycledResidentBytesFromColdBacking": memory.recycledColdResidentBytes,
      "freePageReports": reporting.reports,
      "reportingObservations": reporting.observations,
      "physicalReleasedBytes": NSNull(), "scope": "single-vCPU HVF wire/owner, not Linux/SMP",
    ]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appending(path: "result.json"), options: .withoutOverwriting)
    try require(primary.isEmpty && cleanup.isEmpty && !created && steps.count == 4, "completion")
    print("MEMORY_DEVICE_CHECK_PASS")
  }
}
