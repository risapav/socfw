# STATUS.md — sdram_test_04

| Field | Value |
|-------|-------|
| Project | sdram_test_04 |
| Purpose | AXI adapter over proven native_word_port |
| Current milestone | M5 — COMPLETE |
| Final result | **PASS** |
| Selected config | RSHIFT=0, CMDREG=1 |
| Latest test result | **PASS** — E007: BREADY+RREADY stall 3/3 all stable, ADDR0/4 MATCH (2026-06-21) |
| Status | **CLOSED** (2026-06-21) |

---

## Conclusion

AXI adapter over native_word_port is proven in simulation.

Verified:
- AXI positive write/read
- AXI protocol guards
- AW/W separated handshake
- native_req_ready stall
- BREADY stall
- RREADY stall
- unaligned/partial access SLVERR
- AXI -> native -> PHY -> SDRAM model single write/read
- immediate read-after-BVALID
- AXI multi-address smoke
- full-chain AXI backpressure smoke

The original sdram_test_01 failure (0xzzzz_1234 vs 0x1234_A5C3) was **not reproduced** in
simulation at the AXI adapter layer. The adapter layer is clean. The bug likely manifests
only in hardware (capture timing, I/O delays, or board-level signal integrity), which is
outside the scope of sdram_test_04.

Remaining work:
  Move to sdram_test_05 for Quartus + HW BIST @125 MHz.

---

## Not allowed

Do not extend sdram_test_04 with Quartus, HW, BIST, XFCP, or board files.

---

## Inherited baseline (sdram_test_03)

| Setting | Value | Source |
|---------|-------|--------|
| READ_CAPTURE_SHIFT | 0 | sdram_test_02 sweep |
| CMD_REG_ON_CLK_SH | 1 | sdram_test_02 fixed config |
| native_word_port | proven | sdram_test_03 M1-M3 PASS |
| req_addr = halfword base | AXI addr >> 1 | sdram_test_03 D006 |
