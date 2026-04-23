/* AUTO-GENERATED - DO NOT EDIT */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
  RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 32768
}

SECTIONS {
  . = ORIGIN(RAM);

  .text.reset : {
    KEEP(*(.text.start))
  } > RAM

  . = ORIGIN(RAM) + 0x10;

  .text.irq : {
    KEEP(*(.text.irq))
  } > RAM

  . = ALIGN(4);

  .text : {
    *(.text*)
    *(.rodata*)
  } > RAM

  .data : {
    *(.data*)
  } > RAM

  .bss : {
    __bss_start = .;
    *(.bss*) *(COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } > RAM

  _stack_top  = ORIGIN(RAM) + LENGTH(RAM);
  _stack_size = LENGTH(RAM) * 25 / 100;
  _stack_base = _stack_top - _stack_size;
}
