.section .text.boot,"ax",%progbits
.global _start
_start:
  msr daifset, #0xf
  msr spsel, #1
  adrp x0, __stack_top
  add x0, x0, :lo12:__stack_top
  mov sp, x0
  adrp x4, __exception_vectors
  add x4, x4, :lo12:__exception_vectors
  msr vbar_el1, x4
  isb
  adrp x0, __scratch_start
  add x0, x0, :lo12:__scratch_start
  mov x1, #4096
  adrp x2, __frames_start
  add x2, x2, :lo12:__frames_start
  mov x3, #16
  bl guest_main
1: wfe
  b 1b

.global guest_exit
guest_exit:
  // PSCI SYSTEM_OFF through QEMU virt HVC: no semihosting/host filesystem access.
  mov x0, #0x0008
  movk x0, #0x8400, lsl #16
  hvc #0
2: wfe
  b 2b

.global guest_corrupt_guard
guest_corrupt_guard:
  adrp x1, __stack_chk_guard
  add x1, x1, :lo12:__stack_chk_guard
  ldr x2, [x1]
  eor x2, x2, #1
  str x2, [x1]
  ret
.global guest_test_trap
guest_test_trap:
  brk #0x641
3: wfe
  b 3b

.global guest_test_other_trap
guest_test_other_trap:
  brk #0x642
5: wfe
  b 5b

.global guest_irq_save
guest_irq_save:
  mrs x0, daif
  msr daifset, #2
  isb
  ret
.global guest_irq_restore
guest_irq_restore:
  msr daif, x0
  isb
  ret
.global guest_timer_frequency
guest_timer_frequency:
  mrs x0, cntfrq_el0
  ret
.global guest_timer_counter
guest_timer_counter:
  isb
  mrs x0, cntpct_el0
  ret
.global guest_timer_arm
guest_timer_arm:
  msr cntp_cval_el0, x0
  mov x0, #1
  msr cntp_ctl_el0, x0
  isb
  ret
.global guest_timer_disable
guest_timer_disable:
  msr cntp_ctl_el0, xzr
  isb
  ret
.global guest_device_barrier
guest_device_barrier:
  dsb sy
  ret
.global guest_irq_count_address
guest_irq_count_address:
  adrp x0, __irq_count
  add x0, x0, :lo12:__irq_count
  ret
.global guest_fp_control
guest_fp_control:
  mrs x0, cpacr_el1
  ret
.global guest_frames_start_address
guest_frames_start_address:
  adrp x0, __frames_start
  add x0, x0, :lo12:__frames_start
  ret
.global guest_frames_end_address
guest_frames_end_address:
  adrp x0, __frames_end
  add x0, x0, :lo12:__frames_end
  ret

// All GPRs survive the asynchronous call. The checked Swift profile forbids FP/SIMD.
guest_irq_entry:
  sub sp, sp, #272
  stp x0, x1, [sp, #0]
  stp x2, x3, [sp, #16]
  stp x4, x5, [sp, #32]
  stp x6, x7, [sp, #48]
  stp x8, x9, [sp, #64]
  stp x10, x11, [sp, #80]
  stp x12, x13, [sp, #96]
  stp x14, x15, [sp, #112]
  stp x16, x17, [sp, #128]
  stp x18, x19, [sp, #144]
  stp x20, x21, [sp, #160]
  stp x22, x23, [sp, #176]
  stp x24, x25, [sp, #192]
  stp x26, x27, [sp, #208]
  stp x28, x29, [sp, #224]
  stp x30, xzr, [sp, #240]
  mrs x0, elr_el1
  mrs x1, spsr_el1
  stp x0, x1, [sp, #256]
  bl guest_irq
  ldp x0, x1, [sp, #256]
  msr elr_el1, x0
  msr spsr_el1, x1
  ldp x0, x1, [sp, #0]
  ldp x2, x3, [sp, #16]
  ldp x4, x5, [sp, #32]
  ldp x6, x7, [sp, #48]
  ldp x8, x9, [sp, #64]
  ldp x10, x11, [sp, #80]
  ldp x12, x13, [sp, #96]
  ldp x14, x15, [sp, #112]
  ldp x16, x17, [sp, #128]
  ldp x18, x19, [sp, #144]
  ldp x20, x21, [sp, #160]
  ldp x22, x23, [sp, #176]
  ldp x24, x25, [sp, #192]
  ldp x26, x27, [sp, #208]
  ldp x28, x29, [sp, #224]
  ldp x30, xzr, [sp, #240]
  add sp, sp, #272
  eret

.section .text.vectors,"ax",%progbits
.balign 2048
.global __exception_vectors
__exception_vectors:
.set vector_index, 0
.rept 16
  .balign 128
  .if vector_index == 5
    b guest_irq_entry
  .else
  mov x0, #vector_index
  b guest_exception
  .endif
  .set vector_index, vector_index + 1
.endr
.balign 128
guest_exception:
  msr daifset, #0xf
  adrp x3, __trap_stack_top
  add x3, x3, :lo12:__trap_stack_top
  mov sp, x3
  mrs x1, esr_el1
  mrs x2, far_el1
  bl guest_trap
4: wfe
  b 4b
.section .note.GNU-stack,"",%progbits
