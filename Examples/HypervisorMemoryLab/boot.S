.section .text.boot,"ax"
.global _start
_start:
  bl swift_guest
  dsb sy
  hvc #0
  b .
