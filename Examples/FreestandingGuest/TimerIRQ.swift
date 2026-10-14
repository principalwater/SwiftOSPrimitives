import GuestABI
import _Volatile

// This fixture owns GICv2/PPI30 and a linker-reserved RAM counter on one QEMU virt CPU.

private func register(_ address: UInt) -> VolatileMappedRegister<UInt32> {
  unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: address)
}
private func countRegister() -> VolatileMappedRegister<UInt64> {
  let address = UInt(guest_irq_count_address())
  guard address % 8 == 0, address >= 0x4008_0000, address < 0x4400_0000 - 8 else {
    finish("IRQ_COUNTER_FAIL\n")
  }
  return unsafe VolatileMappedRegister<UInt64>(unsafeBitPattern: address)
}

@c(guest_irq)
public func guestIRQ() {
  let acknowledgement = register(0x0801_000c).load()
  if acknowledgement & 0x3ff == 1023 { return }
  guard acknowledgement & 0x3ff == 30 else { finish("IRQ_UNEXPECTED\n") }
  guest_timer_disable()
  let counter = countRegister()
  counter.store(counter.load() + 1)
  // The device is quiescent before GIC deactivation; the ISA helper supplies DSB.
  guest_device_barrier()
  register(0x0801_0010).store(acknowledgement)
  guest_device_barrier()
}

func checkTimerIRQ() {
  let previous = guest_irq_save()
  guard previous & 0x80 != 0 else { finish("IRQ_ENTRY_UNMASKED\n") }
  guard guest_fp_control() & (3 << 20) == 0 else { finish("IRQ_FP_ENABLED\n") }
  let counter = countRegister()
  counter.store(0)
  let frequency = guest_timer_frequency()
  guard frequency >= 1000 && frequency <= 10_000_000_000 else { finish("IRQ_CLOCK_FAIL\n") }
  register(0x0800_0000).store(1)
  register(0x0801_0004).store(0xff)
  register(0x0801_0000).store(1)
  register(0x0800_041c).store(0xa0a0_a0a0)
  register(0x0800_0280).store(1 << 30)
  register(0x0800_0100).store(1 << 30)
  guest_device_barrier()
  guestIRQ()
  guard counter.load() == 0 else { finish("IRQ_SPURIOUS_FAIL\n") }
  let started = guest_timer_counter()
  let (deadline, overflow) = started.addingReportingOverflow(frequency)
  guard !overflow else { finish("IRQ_CLOCK_FAIL\n") }
  guest_timer_arm(started + frequency / 1000)
  #if !GUEST_IRQ_MASK
    guest_irq_restore(previous & ~UInt64(0x80))
  #endif
  while counter.load() == 0 && guest_timer_counter() < deadline {}
  _ = guest_irq_save()
  guest_timer_disable()
  register(0x0800_0180).store(1 << 30)
  guest_device_barrier()
  let received = counter.load()
  guest_irq_restore(previous)
  if received == 0 { finish("IRQ_TIMEOUT\n") }
  if received != 1 { finish("IRQ_DUPLICATE\n") }
  emit("IRQ_PASS\n")
}
