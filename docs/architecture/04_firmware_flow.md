# Firmware Flow

## Two-pass build

When `firmware.enabled: true`, the build uses a two-pass strategy:

```
Pass 1:
  Load project → elaborate → emit RTL/headers/linker script
  ↓
Firmware compile:
  gcc → ELF → BIN → HEX
  ↓
Pass 2:
  Patch RAM init_file with firmware.hex → re-emit RTL with initialized RAM
```

This ensures the generated `soc_top.sv` has the correct `$readmemh` initialization.

## Linker script generation

The linker script (`sections.lds`) is generated from the address map:

```
. = ORIGIN(RAM) + 0x0;
.text.start : { KEEP(*(.text.start)) } > RAM

. = ORIGIN(RAM) + 0x10;
.text.irq : { KEEP(*(.text.irq)) } > RAM

.text : { *(.text*) } > RAM
.rodata : { *(.rodata*) } > RAM
.data : { *(.data*) } > RAM
.bss : { *(.bss*) } > RAM
```

## IRQ entry ABI

PicoRV32 uses a minimal wrapper ABI:

- IRQ entry at `PROGADDR_IRQ = 0x10`
- `start.S` saves context, calls `irq_handler()`, restores, executes `reti`
- `irq_handler()` reads pending/enable registers and dispatches via `isr_fn_t` table

## Headers generated

- `soc_map.h` — base addresses for all peripherals
- `sections.lds` — linker script with correct memory layout
