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

.section .text.vectors,"ax",%progbits
.balign 2048
.global __exception_vectors
__exception_vectors:
.set vector_index, 0
.rept 16
  .balign 128
  mov x0, #vector_index
  b guest_exception
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
