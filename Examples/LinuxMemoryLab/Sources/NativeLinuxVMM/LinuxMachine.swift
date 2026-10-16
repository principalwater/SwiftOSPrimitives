import Darwin
import Foundation
import Hypervisor
import PageMemory
import Synchronization

enum Failure: Error {
  case arguments, boundary, deadline, protocolError
  case unexpectedExit(UInt32, UInt64, UInt64)
  case native(String, Int32)
}
func check(_ code: Int32, _ operation: String) throws {
  guard code == 0 else { throw Failure.native(operation, code) }
}

// The coordinator owns mappings/devices; each vCPU has its own affine worker.
final class LinuxMachine {
  let thread = pthread_self()
  var created = false
  var wasCreated = false
  var memory: UnsafeMutableRawPointer?
  var capacity = 512 << 20
  let base: UInt64 = 0x4000_0000
  var mapped = false
  var cpuCount = 1
  var cpus: CPUGroup?
  var activeCPU = 0
  var activeRegisters = CPURegisters()
  var running = false
  var console = Data()
  var line = Data()
  var ready = false
  var exits = 0
  var consoleSink: FileHandle?
  var lastPC: UInt64 = 0
  var osLocks = InlineArray<4, Bool>(repeating: false)
  var osLock: Bool {
    get { osLocks[activeCPU] }
    set { osLocks[activeCPU] = newValue }
  }
  var dynamicMemory: MemoryDevice?
  var disk: BlockDevice?
  var rootDisk: BlockDevice?
  var vsock: VsockDevice?
  var networks: [NetworkDevice] = []
  var control: NativeControl?
  var guestEvents: [String] = []
  var input = Data()
  var inputOffset = 0
  var uartMask: UInt64 = 0
  var phase = 0
  var memoryComplete = false

  func feed(_ text: String) throws {
    guard inputOffset == input.count else { throw Failure.protocolError }
    input = Data(text.utf8)
    inputOffset = 0
    try uartIRQ()
  }
  func uartIRQ() throws {
    try check(hv_gic_set_spi(33, inputOffset < input.count && uartMask & 16 != 0), "uart-irq")
  }
  func memoryProgress() throws {
    guard let device = dynamicMemory else { return }
    if disk != nil, phase == 5, device.plugged == UInt64(MemoryDevice.capacity) {
      phase = 6
      try feed("G 2\n")
    } else if disk != nil, phase == 7, device.plugged == 0 {
      phase = 8
      try feed("V 2\n")
    } else if phase == 1, device.plugged == UInt64(MemoryDevice.capacity) {
      phase = 2
      try feed(disk == nil ? "S 1\n" : "L 1\n")
    } else if phase == 3, device.plugged == 0 {
      phase = 4
      try feed(disk == nil ? "S 2\n" : "V 1\n")
    }
  }
  func consoleLine(_ text: String) throws {
    if control != nil {
      if text.contains("Kernel panic") { throw Failure.protocolError }
      return
    }
    if text.hasPrefix("CH_") {
      guard guestEvents.count < 32 else { throw Failure.protocolError }
      guestEvents.append(text.trimmingCharacters(in: .newlines))
      guard let device = dynamicMemory, disk != nil else { throw Failure.protocolError }
      if text.hasPrefix("CH_READY "), phase == 0 {
        ready = true
        phase = 1
      } else if text.hasPrefix("CH_LOAD_RUNNING 1"), phase == 2 {
        try requestMemory(0)
        phase = 3
      } else if text.hasPrefix("CH_SHRUNK 1 "), phase == 4 {
        guard device.plugged == 0 else { throw Failure.protocolError }
        try requestMemory(UInt64(MemoryDevice.capacity))
        phase = 5
      } else if text.hasPrefix("CH_LOAD_RUNNING 2"), phase == 6 {
        try requestMemory(0)
        phase = 7
      } else if text.hasPrefix("CH_SHRUNK 2 "), phase == 8 {
        guard device.plugged == 0 else { throw Failure.protocolError }
        phase = 9
      } else if text.hasPrefix("CH_DONE"), phase == 9 {
        memoryComplete = true
      } else {
        throw Failure.protocolError
      }
    } else if text.hasPrefix("PROBE_READY") {
      ready = true
      if dynamicMemory != nil { phase = 1 }
    } else if text.hasPrefix("PROBE_OBS 1 "), phase == 2, let device = dynamicMemory {
      device.requested = 0
      device.transport.generation &+= 1
      device.transport.interruptStatus |= 2
      try check(hv_gic_set_spi(device.transport.interrupt, true), "memory-config-irq")
      phase = 3
    } else if text.hasPrefix("PROBE_OBS 2 "), phase == 4 {
      memoryComplete = true
    } else if text.hasPrefix("PROBE_FAIL") || text.contains("Kernel panic") {
      throw Failure.protocolError
    }
  }
  func requestMemory(_ size: UInt64) throws {
    guard let device = dynamicMemory, size <= UInt64(MemoryDevice.capacity) else {
      throw Failure.protocolError
    }
    device.requested = size
    device.transport.generation &+= 1
    device.transport.interruptStatus |= 2
    try check(hv_gic_set_spi(device.transport.interrupt, true), "memory-config-irq")
  }
  func blockMMIO(_ offset: UInt64, width: Int, write: UInt32?, target: BlockDevice? = nil) throws
    -> UInt64
  {
    guard let disk = target ?? disk else { throw Failure.protocolError }
    if offset >= 0x100 {
      let bytes = disk.config()
      guard write == nil, width <= 4, offset - 0x100 < UInt64(bytes.count),
        Int(offset - 0x100) + width <= bytes.count
      else { throw Failure.protocolError }
      return (0..<width).reduce(0) { $0 | (UInt64(bytes[Int(offset - 0x100) + $1]) << ($1 * 8)) }
    }
    guard width == 4, offset % 4 == 0 else { throw Failure.protocolError }
    let transport = disk.transport
    if let write {
      if try transport.write(offset, write, memory: pointer) {
        if try transport.queue.drain(
          memory: pointer,
          process: { buffers in
            try disk.process(buffers, memory: self.dataPointer)
          })
        {
          transport.interruptStatus |= 1
        }
      }
      try check(hv_gic_set_spi(transport.interrupt, transport.interruptStatus != 0), "block-irq")
      return 0
    }
    return UInt64(transport.read(offset))
  }
  func dataPointer(_ address: UInt64, _ count: Int) throws -> UnsafeMutableRawPointer {
    try requireStopped()
    if address >= MemoryDevice.base, let device = dynamicMemory, count > 0 {
      let offset = address - MemoryDevice.base
      guard offset < UInt64(MemoryDevice.capacity),
        UInt64(count) <= UInt64(MemoryDevice.block) - offset % UInt64(MemoryDevice.block)
      else { throw Failure.boundary }
      let extent = device.extents[Int(offset / UInt64(MemoryDevice.block))]
      guard extent.plugged, extent.mapped, let pointer = extent.pointer else {
        throw Failure.boundary
      }
      return pointer.advanced(by: Int(offset % UInt64(MemoryDevice.block)))
    }
    return try pointer(address, count)
  }
  func memoryMMIO(_ offset: UInt64, width: Int, write: UInt32?) throws -> UInt64 {
    guard let device = dynamicMemory else { throw Failure.protocolError }
    let transport = device.transport
    if offset >= 0x100 {
      guard write == nil, offset - 0x100 <= 56, width <= 4,
        Int(offset - 0x100) + width <= 56
      else { throw Failure.protocolError }
      let bytes = device.config()
      return (0..<width).reduce(0) { $0 | (UInt64(bytes[Int(offset - 0x100) + $1]) << ($1 * 8)) }
    }
    guard width == 4, offset % 4 == 0 else { throw Failure.protocolError }
    if let write {
      if try transport.write(offset, write, memory: pointer) {
        guard transport.driverFeatures & 2 != 0 else { throw Failure.protocolError }
        if try transport.queue.drain(
          memory: pointer,
          process: { buffers in
            guard buffers.count == 2, !buffers[0].writable, buffers[0].size == 24,
              buffers[1].writable, buffers[1].size == 10
            else { throw Failure.protocolError }
            let request = Data(bytes: try self.pointer(buffers[0].address, 24), count: 24)
            try self.requireStopped()
            let before = device.observations.count
            let response = try device.request(request)
            for index in before..<device.observations.count {
              device.observations[index]["allVCPUsParked"] = self.cpus?.isQuiescent ?? true
              device.observations[index]["quiescentEpoch"] = self.cpus?.epoch ?? 0
              device.observations[index]["vcpuCount"] = self.cpuCount
            }
            let destination = try self.pointer(buffers[1].address, 10)
            response.withUnsafeBytes {
              destination.copyMemory(from: $0.baseAddress!, byteCount: 10)
            }
            return 10
          })
        {
          transport.interruptStatus |= 1
        }
      }
      try check(hv_gic_set_spi(transport.interrupt, transport.interruptStatus != 0), "memory-irq")
      return 0
    }
    return UInt64(transport.read(offset))
  }

  func requireStopped() throws {
    guard pthread_equal(thread, pthread_self()) != 0, !running,
      cpus?.isQuiescent ?? true
    else { throw Failure.boundary }
  }
  func pointer(_ address: UInt64, _ count: Int) throws -> UnsafeMutableRawPointer {
    try requireStopped()
    guard let memory, mapped, count >= 0, address >= base,
      address - base <= UInt64(capacity), UInt64(count) <= UInt64(capacity) - (address - base)
    else { throw Failure.boundary }
    return memory.advanced(by: Int(address - base))
  }
  func load(_ data: Data, at address: UInt64) throws {
    let destination = try pointer(address, data.count)
    data.withUnsafeBytes { destination.copyMemory(from: $0.baseAddress!, byteCount: data.count) }
    sys_icache_invalidate(destination, data.count)
  }
  func register(_ reg: hv_reg_t) throws -> UInt64 {
    let index = try CPURegisters.index(reg)
    guard activeRegisters.available & (1 << index) != 0 else { throw Failure.boundary }
    return activeRegisters.values[index]
  }
  func set(_ reg: hv_reg_t, _ value: UInt64) throws {
    try activeRegisters.set(reg, value)
  }
  func boot(kernel: Data, initrd: Data) throws {
    try requireStopped()
    guard !initrd.isEmpty || control != nil, kernel.count >= 64,
      kernel[56..<60].elementsEqual([0x41, 0x52, 0x4d, 0x64])
    else { throw Failure.arguments }
    try check(hv_vm_create(nil), "create")
    created = true
    wasCreated = true
    let gic = hv_gic_config_create()
    try check(hv_gic_config_set_distributor_base(gic, 0x0800_0000), "gic-dist")
    try check(hv_gic_config_set_redistributor_base(gic, 0x080a_0000), "gic-redist")
    try check(hv_gic_create(gic), "gic-create")
    try check(hv_vm_allocate(&memory, capacity, 0), "allocate")
    try check(
      mach_vm_inherit(
        mach_task_self_, UInt64(UInt(bitPattern: memory!)), UInt64(capacity), VM_INHERIT_NONE),
      "boot-memory-inherit-none")
    try check(
      hv_vm_map(
        memory!, base, capacity,
        UInt64(HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC)), "map")
    mapped = true
    let initrdAddress: UInt64 = base + 128 * 1024 * 1024
    let dtbAddress: UInt64 = base + 120 * 1024 * 1024
    var command =
      "console=ttyAMA0 earlycon=pl011,mmio32,0x09000000 rdinit=/init panic=-1 nokaslr loglevel=6 memhp_default_state=online_movable memory_hotplug.memmap_on_memory=0 irqchip.gicv3_nolpi=1"
    if control != nil {
      command = command.replacingOccurrences(
        of: "rdinit=/init", with: "root=/dev/vda rootfstype=ext4 ro init=/sbin/vminitd")
      // Serial INFO output traps once per byte and forces SMP quiescence for every character.
      command += " -- agent --log-level warning"
    }
    let tree = DeviceTree.linux(
      memoryBytes: UInt64(capacity),
      initrd: initrdAddress..<(initrdAddress + UInt64(initrd.count)), command: command,
      memoryDevice: dynamicMemory != nil, blockDevice: disk != nil, container: control != nil,
      cpuCount: cpuCount, networkCount: networks.count)
    guard kernel.count < 100 << 20, initrd.count < 64 << 20 else { throw Failure.arguments }
    let textOffset = kernel[8..<16].enumerated().reduce(UInt64(0)) {
      $0 | (UInt64($1.element) << ($1.offset * 8))
    }
    guard textOffset <= 0x80000 else { throw Failure.arguments }
    try load(kernel, at: base + textOffset)
    if !initrd.isEmpty { try load(initrd, at: initrdAddress) }
    try load(tree, at: dtbAddress)
    let pool = CPUGroup()
    cpus = pool
    try pool.create(count: cpuCount)
    _ = try pool.activate(0, pc: base + textOffset, context: dtbAddress)
    let deadline = ContinuousClock.now.advanced(by: .seconds(disk == nil ? 45 : 120))
    control?.state.withLock { $0.running = true }
    while control != nil || (dynamicMemory == nil ? !ready : !memoryComplete) {
      if let control, let vsock {
        let releaseAlias = control.state.withLock {
          let requested = $0.releaseAlias
          $0.releaseAlias = false
          return requested
        }
        if releaseAlias, let device = dynamicMemory {
          try device.releaseAlias()
          // Linux BUSY retry starts at50s; changed availability needs an explicit config event.
          try requestMemory(device.requested)
        }
        control.state.withLock { $0.refusals = dynamicMemory?.refusals.count ?? 0 }
        for network in networks {
          try network.poll(memory: pointer, payloadMemory: dataPointer)
          try check(
            hv_gic_set_spi(network.transport.interrupt, network.transport.interruptStatus != 0),
            "net-irq")
        }
        let update = control.state.withLock { state in
          state.plugged = dynamicMemory?.plugged ?? 0
          return (state.stop, state.requested)
        }
        if update.0 { break }
        // Pop one ownership transfer at a time; an exception leaves every other fd in State.
        for _ in 0..<64 {
          let command = control.state.withLock { state -> NativeControl.Command? in
            guard !state.stop, !state.commands.isEmpty else { return nil }
            return state.commands.removeFirst()
          }
          guard let command else { break }
          switch command {
          case .open(let port, let fd, let token):
            try vsock.open(port, descriptor: fd, token: token)
          case .cancel(let token): vsock.cancel(token)
          }
        }
        if dynamicMemory?.requested != update.1 { try requestMemory(update.1) }
        try vsock.poll(memory: pointer, payloadMemory: dataPointer)
        try check(hv_gic_set_spi(38, vsock.transport.interruptStatus != 0), "vsock-irq")
      } else {
        try memoryProgress()
      }
      guard ContinuousClock.now < deadline, exits < 3_000_000 else { throw Failure.deadline }
      running = true
      let events: [(Int, CPUExit)]
      do { events = try pool.runEpoch() } catch {
        running = false
        throw error
      }
      running = false
      for (index, event) in events {
        activeCPU = index
        activeRegisters = event.registers
        try handleExit(event)
        try pool.update(index, registers: activeRegisters)
      }
    }
  }
  private func handleExit(_ event: CPUExit) throws {
    exits += 1
    lastPC = try register(HV_REG_PC)
    if event.reason == HV_EXIT_REASON_CANCELED.rawValue { return }
    guard event.reason == HV_EXIT_REASON_EXCEPTION.rawValue else {
      throw Failure.unexpectedExit(event.reason, event.syndrome, 0)
    }
    let syndrome = event.syndrome
    switch syndrome >> 26 {
    case 0x16:  // HVF resumes after HVC; advancing again skips Linux's next instruction.
      let call = try register(HV_REG_X0)
      switch call {
      case 0x8400_0000: try set(HV_REG_X0, 2)
      case 0xc400_0003, 0x8400_0003:
        let target = try register(HV_REG_X1)
        let entry = try register(HV_REG_X2)
        let context = try register(HV_REG_X3)
        guard let cpus else { throw Failure.boundary }
        if target < UInt64(cpuCount), entry >= base, entry < base + UInt64(capacity),
          entry % 4 == 0
        {
          let started = try cpus.activate(Int(target), pc: entry, context: context)
          try set(HV_REG_X0, started ? 0 : UInt64(bitPattern: -4))
        } else {
          try set(HV_REG_X0, UInt64(bitPattern: -2))
        }
      case 0xc400_0004, 0x8400_0004:
        let target = try register(HV_REG_X1)
        try set(
          HV_REG_X0,
          target < UInt64(cpuCount) ? (cpus!.powered(Int(target)) ? 0 : 1) : UInt64(bitPattern: -2))
      case 0x8400_0006: try set(HV_REG_X0, 2)
      case 0x8400_000a: try set(HV_REG_X0, UInt64.max)
      default: try set(HV_REG_X0, UInt64.max)
      }
    case 0x18:
      let op0 = (syndrome >> 20) & 3
      let op1 = (syndrome >> 14) & 7
      let crn = (syndrome >> 10) & 15
      let crm = (syndrome >> 1) & 15
      let op2 = (syndrome >> 17) & 7
      let rt = UInt32((syndrome >> 5) & 31)
      let read = syndrome & 1 != 0
      guard op0 == 2, op1 == 0, crn == 1, op2 == 4 else {
        throw Failure.unexpectedExit(event.reason, syndrome, 0)
      }
      switch crm {
      case 0 where !read:  // OSLAR: virtual OS lock state, no host debug access.
        osLock = try rt != 31 && register(hv_reg_t(rawValue: rt)) & 1 != 0
      case 1 where read:  // OSLSR: architectural OS lock model, bit1 is OSLK.
        if rt != 31 { try set(hv_reg_t(rawValue: rt), 8 | (osLock ? 2 : 0)) }
      case 3:  // OSDLR is RAZ/WI on the virtual debug interface.
        if read, rt != 31 { try set(hv_reg_t(rawValue: rt), 0) }
      default: throw Failure.unexpectedExit(event.reason, syndrome, 0)
      }
      try set(HV_REG_PC, register(HV_REG_PC) + 4)
    case 0x24:
      guard syndrome & (1 << 24) != 0 else {
        throw Failure.unexpectedExit(
          event.reason, syndrome, event.physicalAddress)
      }
      let address = event.physicalAddress
      let rt = UInt32((syndrome >> 16) & 31)
      let width = 1 << Int((syndrome >> 22) & 3)
      if address >= 0x0a00_4000, address < 0x0a00_6000 {
        let index = Int((address - 0x0a00_4000) / 0x1000)
        guard networks.indices.contains(index) else { throw Failure.boundary }
        let network = networks[index]
        let offset = (address - 0x0a00_4000) % 0x1000
        let write = syndrome & 64 != 0
        let value: UInt64
        if offset >= 0x100 {
          let config = network.config()
          guard !write, width <= 4, offset - 0x100 + UInt64(width) <= config.count else {
            throw Failure.boundary
          }
          value = (0..<width).reduce(0) {
            $0 | UInt64(config[Int(offset - 0x100) + $1]) << ($1 * 8)
          }
        } else {
          guard width == 4, offset % 4 == 0 else { throw Failure.boundary }
          if write {
            _ = try network.transport.write(
              offset,
              UInt32(truncatingIfNeeded: rt == 31 ? 0 : try register(hv_reg_t(rawValue: rt))),
              memory: pointer)
            try network.poll(memory: pointer, payloadMemory: dataPointer)
            value = 0
          } else {
            value = UInt64(network.transport.read(offset))
          }
        }
        try check(
          hv_gic_set_spi(network.transport.interrupt, network.transport.interruptStatus != 0),
          "net-irq")
        if !write, rt != 31 { try set(hv_reg_t(rawValue: rt), value) }
        try set(HV_REG_PC, register(HV_REG_PC) + 4)
        return
      }
      if address >= 0x0a00_3000, address < 0x0a00_4000, let vsock {
        let write = syndrome & 64 != 0
        let offset = address - 0x0a00_3000
        let value: UInt64
        if offset >= 0x100 {
          guard !write, width <= 4, offset <= 0x104 else { throw Failure.protocolError }
          value = offset == 0x100 ? 3 : 0
        } else {
          guard width == 4, offset % 4 == 0 else { throw Failure.protocolError }
          if write {
            let raw = UInt32(
              truncatingIfNeeded: rt == 31 ? 0 : try register(hv_reg_t(rawValue: rt)))
            if try vsock.transport.write(offset, raw, memory: pointer) {
              try vsock.notify(raw, memory: pointer, payloadMemory: dataPointer)
            }
            value = 0
          } else {
            value = UInt64(vsock.transport.read(offset))
          }
        }
        try check(hv_gic_set_spi(38, vsock.transport.interruptStatus != 0), "vsock-irq")
        if !write, rt != 31 { try set(hv_reg_t(rawValue: rt), value) }
        try set(HV_REG_PC, register(HV_REG_PC) + 4)
        return
      }
      if address >= 0x0a00_2000, address < 0x0a00_3000, let rootDisk {
        let write = syndrome & 64 != 0
        let value = try blockMMIO(
          address - 0x0a00_2000, width: width,
          write: write
            ? UInt32(truncatingIfNeeded: rt == 31 ? 0 : try register(hv_reg_t(rawValue: rt)))
            : nil,
          target: rootDisk)
        if !write, rt != 31 { try set(hv_reg_t(rawValue: rt), value) }
        try set(HV_REG_PC, register(HV_REG_PC) + 4)
        return
      }
      if address >= 0x0a00_1000, address < 0x0a00_2000, disk != nil {
        let write = syndrome & 64 != 0
        let value = try blockMMIO(
          address - 0x0a00_1000, width: width,
          write: write
            ? UInt32(truncatingIfNeeded: rt == 31 ? 0 : try register(hv_reg_t(rawValue: rt)))
            : nil)
        if !write, rt != 31 { try set(hv_reg_t(rawValue: rt), value) }
        try set(HV_REG_PC, register(HV_REG_PC) + 4)
        return
      }
      if address >= 0x0a00_0000, address < 0x0a00_1000, dynamicMemory != nil {
        let write = syndrome & 64 != 0
        let value = try memoryMMIO(
          address - 0x0a00_0000, width: width,
          write: write
            ? UInt32(truncatingIfNeeded: rt == 31 ? 0 : try register(hv_reg_t(rawValue: rt)))
            : nil)
        if !write, rt != 31 { try set(hv_reg_t(rawValue: rt), value) }
        try set(HV_REG_PC, register(HV_REG_PC) + 4)
        return
      }
      guard address >= 0x0900_0000, address < 0x0900_1000, width <= 4 else {
        throw Failure.unexpectedExit(event.reason, syndrome, address)
      }
      let offset = address - 0x0900_0000
      let reg = hv_reg_t(rawValue: rt)
      if syndrome & 64 != 0 {
        let value = rt == 31 ? 0 : try register(reg)
        if offset == 0 {
          guard console.count < 2 << 20, line.count < 8192 else { throw Failure.boundary }
          let byte = UInt8(truncatingIfNeeded: value)
          console.append(byte)
          line.append(byte)
          if byte == 10 {
            try consoleSink?.write(contentsOf: line)
            try consoleLine(String(decoding: line, as: UTF8.self))
            line.removeAll(keepingCapacity: true)
          }
        } else if offset == 0x38 {
          uartMask = value
          try uartIRQ()
        } else if offset == 0x44 {
          try uartIRQ()
        }
      } else if rt != 31 {
        let value: UInt64
        switch offset {
        case 0:
          if inputOffset < input.count {
            value = UInt64(input[inputOffset])
            inputOffset += 1
            try uartIRQ()
          } else {
            value = 0
          }
        case 0x18: value = inputOffset < input.count ? 0x81 : 0x91
        case 0x38: value = uartMask
        case 0x3c: value = inputOffset < input.count ? 16 : 0
        case 0x40: value = inputOffset < input.count ? uartMask & 16 : 0
        case 0xfe0: value = 0x11
        case 0xfe4: value = 0x10
        case 0xfe8: value = 0x14
        case 0xfec: value = 0
        case 0xff0: value = 0x0d
        case 0xff4: value = 0xf0
        case 0xff8: value = 0x05
        case 0xffc: value = 0xb1
        default: value = 0
        }
        try set(reg, value)
      }
      try set(HV_REG_PC, register(HV_REG_PC) + 4)
    default:
      throw Failure.unexpectedExit(
        event.reason, syndrome, event.physicalAddress)
    }
  }
  func close() -> [String] {
    var errors: [String] = []
    guard pthread_equal(thread, pthread_self()) != 0 else { return ["coordinator-thread"] }
    if let cpus {
      let failures = cpus.close()
      guard failures.isEmpty else { return failures }
    }
    do { try requireStopped() } catch { return [String(describing: error)] }
    for network in networks {
      do { try network.close() } catch { errors.append("net-close \(error)") }
    }
    do { try rootDisk?.close() } catch { errors.append("root-disk-close \(error)") }
    do { try disk?.close() } catch { errors.append("disk-close \(error)") }
    do { try dynamicMemory?.close() } catch {
      errors.append("memory-close \(error)")
      return errors
    }
    if mapped {
      let result = hv_vm_unmap(base, capacity)
      if result == 0 { mapped = false } else { errors.append("unmap \(result)") }
    }
    if let memory, !mapped {
      let result = hv_vm_deallocate(memory, capacity)
      if result == 0 { self.memory = nil } else { errors.append("deallocate \(result)") }
    }
    if created {
      let result = hv_vm_destroy()
      if result == 0 { created = false } else { errors.append("destroy \(result)") }
    }
    return errors
  }
}

public enum StandaloneLab {
  public static func main() {
    do { try run() } catch {
      print("LINUX_LAB_FAIL \(error)")
      exit(1)
    }
  }
  private static func run() throws {
    let args = CommandLine.arguments
    guard (4...6).contains(args.count) else { throw Failure.arguments }
    let output = URL(filePath: args[3])
    guard !FileManager.default.fileExists(atPath: output.path) else { throw Failure.arguments }
    try FileManager.default.createDirectory(
      at: output, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let vm = LinuxMachine()
    if args.count >= 5 {
      guard ["memory", "held", "alias"].contains(args[4]) else { throw Failure.arguments }
      vm.dynamicMemory = MemoryDevice(held: args[4] == "held", aliasControl: args[4] == "alias")
    }
    if args.count == 6 {
      vm.capacity = 1024 << 20
      vm.disk = try BlockDevice(path: args[5])
    }
    let livePath = output.appending(path: "live-console.log").path
    guard FileManager.default.createFile(atPath: livePath, contents: nil) else {
      throw Failure.boundary
    }
    let live = try FileHandle(forWritingTo: URL(filePath: livePath))
    vm.consoleSink = live
    defer { try? live.close() }
    var primary = ""
    do {
      let kernel = try Data(contentsOf: URL(filePath: args[1]), options: .mappedIfSafe)
      let initrd = try Data(contentsOf: URL(filePath: args[2]), options: .mappedIfSafe)
      try vm.boot(kernel: kernel, initrd: initrd)
    } catch { primary = String(describing: error) }
    let cleanup = vm.close()
    try vm.console.write(to: output.appending(path: "console.log"), options: .withoutOverwriting)
    let result: [String: Any] = [
      "ready": vm.ready, "primaryError": primary,
      "cleanupErrors": cleanup, "memoryComplete": vm.memoryComplete,
      "memoryObservations": vm.dynamicMemory?.observations ?? [],
      "guestEvents": vm.guestEvents, "diskBytesWritten": vm.disk?.written ?? 0,
      "vmDestroyed": !vm.created, "exits": vm.exits,
      "lastPC": String(vm.lastPC, radix: 16), "physicalReleasedBytes": NSNull(),
      "scope": vm.disk != nil ? "real Linux ClickHouse virtio-mem" : "real Linux HVF",
    ]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appending(path: "result.json"), options: .withoutOverwriting)
    guard primary.isEmpty, cleanup.isEmpty, vm.ready, !vm.created,
      vm.dynamicMemory == nil || vm.memoryComplete
    else { throw Failure.protocolError }
    print("LINUX_LAB_PASS")
  }
}
