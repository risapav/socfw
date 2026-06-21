# docs/01_GOAL.md — Project Goal

## Goal

Can we perform one native 32-bit write and one native 32-bit read through the SDRAM
internal core without AXI?

## Context

sdram_test_02 proved that the isolated PHY and 2×16→32 assembler are correct at RSHIFT=0.
The AXI 2-read failure from sdram_test_01 is above the PHY/assembler layer.

sdram_test_03 adds the minimal integration step: a `native_word_port` module that
translates 32-bit requests into 2×16-bit PHY sub-commands, without any AXI dependency.

## Success criterion

```
write addr 0x00000000 = 32'h1234_A5C3
read  addr 0x00000000
rdata                 = 32'h1234_A5C3
```

## Not in scope

- AXI (return to sdram_test_04 after this passes)
- Scheduler, refresh manager, bank machines
- BIST
- Quartus / HW
- XFCP
