# docs/01_GOAL.md — Goal

## Primary question

Can an AXI-lite 32-bit transaction be correctly translated into one
`native_word_port` transaction, and does the original sdram_test_01
read bug manifest at this layer?

## Original bug (sdram_test_01)

```
expected 0x1234_A5C3
got      0xzzzz_1234
```

Upper halfword is Hi-Z while lower halfword is correct.
Characteristic of a read-path capture, assembly, or handshake issue.

## Chain of proof

```
sdram_test_02: PHY + 2x16 + assembler -> RSHIFT=0 PASS
sdram_test_03: native_word_port unit + single R/W + multi-addr -> PASS
sdram_test_04: AXI adapter -> investigate bug at this layer
```

## Scope

Simulation only.

No Quartus. No HW. No BIST. No XFCP.

Modules under test:
- M1: axi_native_adapter only (fake native backend)
- M2: axi_native_adapter + native_word_port + sdram_phy + sdram_model_pro
- M3: multi-address AXI smoke
- M4: AXI backpressure smoke
- M5: closeout
