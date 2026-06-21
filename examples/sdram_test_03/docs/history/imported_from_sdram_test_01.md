# Inherited context from sdram_test_01

## Original problem (sdram_test_01 E007/E008)

sdram_test_01 found two failures during M0b validation:

**E007 (RSHIFT=-1):** READ_IDX=2. PHY captures at same cycle model drives DQ via NBA.
Pre-NBA capture → dq_i=Hi-Z.

**E008 (RSHIFT=0):** PHY/scheduler single-read PASS. AXI 2-read path returns 0xzzzz1234.
Root cause: unknown extra cycle in AXI path.

## Handover chain

```
sdram_test_01 E007/E008 → sdram_test_02 (isolated PHY+assembler)
sdram_test_02 M4 PASS   → sdram_test_03 (native_word_port integration)
sdram_test_03 (target)  → sdram_test_04 (AXI adapter, return to original problem)
```

## W9825G6KH-6 parameters (fixed)

| Parameter | Value |
|-----------|-------|
| CAS latency | 3 |
| Burst length | 1 |
| Clock | 125 MHz |
| Interface | 16-bit |

## Key constraint

The AXI 2-read bug (0xzzzz1234) means the upper halfword is Hi-Z while the lower is
correct. This is characteristic of a capture-window or dq_oe timing issue in the read
path when a 32-bit word is assembled from two consecutive 16-bit reads through the AXI
gearbox. sdram_test_02 ruled out the PHY and assembler as the source.
