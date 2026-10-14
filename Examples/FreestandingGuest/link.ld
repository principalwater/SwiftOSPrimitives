ENTRY(_start)
PHDRS {
  text PT_LOAD FLAGS(5);
  rodata PT_LOAD FLAGS(4);
  data PT_LOAD FLAGS(6);
  stack PT_GNU_STACK FLAGS(6);
}
SECTIONS {
  . = 0x40080000;
  .text : { KEEP(*(.text.boot)) *(.text .text.*) } :text
  . = ALIGN(4096);
  .rodata : { *(.rodata .rodata.*) *(.swift_modhash) *(.swift1_autolink_entries) } :rodata
  .eh_frame : { *(.eh_frame .eh_frame.*) } :rodata
  .gcc_except_table : { *(.gcc_except_table .gcc_except_table.*) } :rodata
  . = ALIGN(4096);
  .data : { *(.data .data.*) } :data
  .bss (NOLOAD) : {
    *(.bss .bss.*) *(COMMON)
    . = ALIGN(4096);
    __scratch_start = .;
    . += 4096;
    . = ALIGN(16);
    __stack_bottom = .;
    . += 65536;
    __stack_top = .;
  } :data
  .symtab 0 : { *(.symtab) } :NONE
  .strtab 0 : { *(.strtab) } :NONE
  .shstrtab 0 : { *(.shstrtab) } :NONE
  /DISCARD/ : { *(.comment) *(.note.GNU-stack) *(.llvm_addrsig) }
  ASSERT(__stack_top < 0x44000000, "Guest image exceeds the 64MiB RAM extent")
}
