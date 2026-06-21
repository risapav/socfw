# STATUS.md — sdram_test_04

| Field | Value |
|-------|-------|
| Project | sdram_test_04 |
| Purpose | AXI adapter over proven native_word_port |
| Current milestone | M1c — AXI assertion hardening |
| Current active test | tb_axi_native_adapter_protocol_unit |
| Selected config | RSHIFT=0, CMDREG=1 |
| Latest test result | **PASS** — E003: 54 checks (P3×12 + P4×12 + P5×12 + E1-E3×6), no RTL change (2026-06-21) |
| Next allowed action | M2 awaiting user approval |

---

## Goal

Find and fix the original sdram_test_01 AXI 2-read bug:

```
expected 0x1234_A5C3
got      0xzzzz_1234
```

Lower layers proven:
- sdram_test_02: PHY + 2×16 assembly PASS
- sdram_test_03: native_word_port (unit + single + multi-address) PASS

Suspect: AXI adapter / address conversion / handshake / response timing / backpressure

---

## Not allowed

- Quartus / HW / board.yaml
- BIST, XFCP
- Modifying native_word_port.sv (proven baseline)
- Claim PASS without valid log header

---

## Inherited baseline (sdram_test_03)

| Setting | Value | Source |
|---------|-------|--------|
| READ_CAPTURE_SHIFT | 0 | sdram_test_02 sweep |
| CMD_REG_ON_CLK_SH | 1 | sdram_test_02 fixed config |
| native_word_port | proven | sdram_test_03 M1-M3 PASS |
| req_addr = halfword base | AXI addr >> 1 | sdram_test_03 D006 |
