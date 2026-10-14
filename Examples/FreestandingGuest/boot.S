.section .text.boot,"ax",%progbits
.global _start
_start:
  msr daifset, #0xf
  adrp x0, __stack_top
  add x0, x0, :lo12:__stack_top
  mov sp, x0
  adrp x0, __scratch_start
  add x0, x0, :lo12:__scratch_start
  mov x1, #4096
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
.section .note.GNU-stack,"",%progbits
