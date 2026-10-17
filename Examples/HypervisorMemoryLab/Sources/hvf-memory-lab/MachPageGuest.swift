import Darwin
import Foundation
import Hypervisor

/// Synthetic EL1 reader on the experiment's only vCPU. The whole program is two instructions,
/// `ldr x2, [x1]` then `hvc #0`, so one `hv_vcpu_run` observes exactly one guest-physical word.
/// The vCPU belongs to the creating thread and is never run while the host mutates a mapping.
final class MachPageGuest {
  enum Observation {
    /// HVC reached with the program-counter semantics the pre-entry qualification established.
    case value(UInt64)
    /// Stage-2 translation fault on a read of the requested frame: PC and X2 are unchanged, so
    /// the load did not complete. `exactAddress` records whether HVF reported the full address.
    case translationFault(exactAddress: Bool)
    case unexpected(String)
  }

  // ldr x2, [x1] ; hvc #0
  static let words: [UInt32] = [0xf940_0022, 0xd400_0002]
  static let entryCPSR: UInt64 = 0x3c5
  static let sentinel: UInt64 = 0xa5a5_0000_0000_0001
  static let exitPC = MachPageGeometry.codeGPA + UInt64(words.count * 4)

  let machine: Machine
  let cpu: hv_vcpu_t
  private let record: UnsafeMutablePointer<hv_vcpu_exit_t>
  private(set) var runs = 0

  init(machine: Machine, cpu: hv_vcpu_t, record: UnsafeMutablePointer<hv_vcpu_exit_t>) {
    self.machine = machine
    self.cpu = cpu
    self.record = record
  }

  /// Same sequence as the reviewed lab: RW while loading, instruction-cache invalidate, R+X
  /// before any vCPU exists, the host alias read-only, then an instruction-word read-back.
  static func install(in machine: Machine) throws {
    let code = try machine.allocate(
      address: MachPageGeometry.codeGPA, size: MachPageGeometry.pageSize)
    guard let pointer = code.pointer else { throw Failure.state }
    for (index, word) in words.enumerated() {
      pointer.storeBytes(of: word.littleEndian, toByteOffset: index * 4, as: UInt32.self)
    }
    sys_icache_invalidate(pointer, code.size)
    try check(
      hv_vm_protect(code.address, code.size, UInt64(HV_MEMORY_READ | HV_MEMORY_EXEC)),
      "protect-code-rx")
    try check(
      mach_vm_protect(
        mach_task_self_, UInt64(UInt(bitPattern: pointer)), UInt64(code.size), 0, VM_PROT_READ),
      "protect-code-host-ro")
    for (index, word) in words.enumerated() {
      let stored = pointer.load(fromByteOffset: index * 4, as: UInt32.self)
      guard UInt32(littleEndian: stored) == word else { throw Failure.observation }
    }
  }

  /// Reads the 8-byte word at a guest-physical address. A failed native call throws; anything
  /// the guest does that is not the two specified exits is reported as `unexpected`.
  func read(_ address: UInt64) throws -> Observation {
    try machine.confined()
    try check(hv_vcpu_set_reg(cpu, HV_REG_PC, MachPageGeometry.codeGPA), "set-pc")
    try check(hv_vcpu_set_reg(cpu, HV_REG_CPSR, Self.entryCPSR), "set-cpsr")
    // X0 selects a hypercall; random canary words must never select a host service.
    try check(hv_vcpu_set_reg(cpu, HV_REG_X0, 0x41), "set-return-tag")
    try check(hv_vcpu_set_reg(cpu, HV_REG_X2, Self.sentinel), "set-x2")
    try check(hv_vcpu_set_reg(cpu, HV_REG_X1, address), "set-x1")
    machine.running = true
    let code = hv_vcpu_run(cpu)
    machine.running = false
    try check(code, "run")
    runs += 1
    let event = record.pointee
    var pc: UInt64 = 0
    var x2: UInt64 = 0
    try check(hv_vcpu_get_reg(cpu, HV_REG_PC, &pc), "get-pc")
    try check(hv_vcpu_get_reg(cpu, HV_REG_X2, &x2), "get-x2")
    guard event.reason == HV_EXIT_REASON_EXCEPTION else {
      return .unexpected("exit reason \(event.reason.rawValue) pc=\(pc) x2=\(x2)")
    }
    let syndrome = event.exception.syndrome
    let faulting = event.exception.physical_address
    if syndrome >> 26 == 0x16, syndrome & 0xffff == 0, pc == Self.exitPC { return .value(x2) }
    // Data abort from a lower level, stage-2 translation fault class, caused by a read.
    if syndrome >> 26 == 0x24, syndrome & 0x3c == 0x04, syndrome & 0x40 == 0,
      faulting >> 12 == address >> 12, pc == MachPageGeometry.codeGPA, x2 == Self.sentinel
    {
      return .translationFault(exactAddress: faulting == address)
    }
    return .unexpected(
      "syndrome=0x\(String(syndrome, radix: 16)) pc=0x\(String(pc, radix: 16)) "
        + "x2=0x\(String(x2, radix: 16)) ipa=0x\(String(faulting, radix: 16)) "
        + "for 0x\(String(address, radix: 16))")
  }
}
