# docs/03_TEST_PLAN.md — Test Plan

## Fixed configuration

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| READ_CAPTURE_SHIFT | 0 | sdram_test_02 sweep: minimum safe capture |
| CMD_REG_ON_CLK_SH | 1 | sdram_test_02 fixed config |
| CAS_LATENCY | 3 | W9825G6KH-6 at 125 MHz (M2+ only) |

## Address conversion

```
AXI byte addr  -> native halfword base addr
0x00000000     -> 0
0x00000004     -> 2
0x00000008     -> 4
formula: native_req_addr = axi_addr >> 1
```

## Test 1 (M1): tb_axi_native_adapter_unit — E001

**Command:** `make test-axi-unit`

Fake native backend: native_req_ready=1 always, native_rsp_valid injected by TB.
No PHY. No SDRAM model.

Sequence:
1. AXI write AWADDR=0x000000 WDATA=0x1234_A5C3 WSTRB=4'b1111
   → verify native_req_write=1, native_req_addr=0, native_req_wdata=0x1234_A5C3
   → verify BVALID=1, BRESP=OKAY
2. AXI read ARADDR=0x000000, inject native_rsp_valid=1 rdata=0x1234_A5C3
   → verify RVALID=1, RRESP=OKAY, RDATA=0x1234_A5C3
3. AXI write AWADDR=0x000004 WDATA=0xDEAD_BEEF WSTRB=4'b1111
   → verify native_req_addr=2, native_req_wdata=0xDEAD_BEEF
   → verify BVALID=1, BRESP=OKAY
4. AXI read ARADDR=0x000004, inject native_rsp_rdata=0xDEAD_BEEF
   → verify RDATA=0xDEAD_BEEF

Status: **PASS** E001 (2026-06-21)

---

## Test 2 (M1b): tb_axi_native_adapter_protocol_unit — E002

**Command:** `make test-axi-protocol`

Fake native backend (same as M1). Tests protocol guards and channel stalls.

| Test | Scenario | Expected |
|------|----------|----------|
| P1 | AW first then W, addr=0x00, wstrb=4'b1111 | native_req issued, BRESP=OKAY |
| P2 | W first then AW, addr=0x04, wstrb=4'b1111 | native_req issued, BRESP=OKAY |
| P3 | native_req_ready held low 3 cy | native_req_valid stable, BRESP=OKAY after ready |
| P4 | BREADY held low 3 cy after write | BVALID stable, BRESP=OKAY |
| P5 | RREADY held low 3 cy after read | RVALID stable, RDATA stable, RRESP=OKAY |
| E1 | AWADDR=0x02 (unaligned), wstrb=4'b1111 | no native_req, BRESP=SLVERR |
| E2 | AWADDR=0x00, WSTRB=4'b0011 (partial) | no native_req, BRESP=SLVERR |
| E3 | ARADDR=0x02 (unaligned) | no native_req, RRESP=SLVERR, RDATA=0 |

Status: **PASS** E002 (2026-06-21)

---

## Test 3 (M2b): tb_axi_native_raw_read_after_bvalid — E005

**Command:** `make test-axi-raw-raw`

Full integration (same DUTs as M2). AR issued immediately after BVALID accepted — no
manual `native_req_ready` wait, no tWR gap.

Hazard under test: AXI adapter issues BVALID when NWP *accepts* the write request
(ST_WR_ISSU → ST_BVALID transition), not when the SDRAM write physically completes.
Does an immediate subsequent read corrupt data?

| Event | cyc/sh | Notes |
|-------|--------|-------|
| AXI AW+W handshake | cyc=12 | AW+W simultaneous |
| AXI BVALID | cyc=13 | adapter ST_BVALID |
| SDRAM CMD_WR lo | sh=14 | NWP in ST_WR_LOW |
| SDRAM CMD_WR hi | sh=16 | NWP in ST_WR_HIGH |
| AXI AR handshake | cyc=15 | immediate after BVALID |
| NWP req_ready (wr done) | cyc=19 | NWP returns to IDLE |
| SDRAM CMD_RD lo | sh=19 | NWP in ST_RD_LOW |
| SDRAM CMD_RD hi | sh=20 | NWP in ST_RD_HIGH |
| dq_i_valid lo | sh=24 | CL=3 pipeline |
| dq_i_valid hi | sh=25 | |
| AXI RVALID | cyc=27 | rdata=0x1234_A5C3 MATCH |

Conclusion: `BVALID_BEFORE_WRITE_COMPLETE = YES` (cyc=13 < cyc=19). Despite early BVALID,
data integrity is preserved. ST_RD_ISSU waits for `native_req_ready=1` before starting
the read — NWP naturally serializes write then read even without any TB-level delay.

Status: **PASS** E005 (2026-06-21)

---

## Test 4 (M3): tb_axi_native_multi_address_smoke — E006

**Command:** `make test-axi-multi`

Full integration (same DUTs as M2). 3 back-to-back writes then 3 sequential reads at
AXI addrs 0x00, 0x04, 0x08. No manual `native_req_ready` wait; AXI-visible completion only.
Single ACTIVE B0 R0 covers all 6 operations (no auto-precharge, AP=0 in addr_in_w).

| Addr (AXI) | Native addr | WDATA | Expected RDATA |
|------------|-------------|-------|----------------|
| 0x000000 | 0 | 0x1234_A5C3 | 0x1234_A5C3 |
| 0x000004 | 2 | 0xDEAD_BEEF | 0xDEAD_BEEF |
| 0x000008 | 4 | 0xCAFE_5678 | 0xCAFE_5678 |

| Event | cyc | Notes |
|-------|-----|-------|
| W0 AW+W | 12 | adapter IDLE, accepted immediately |
| W0 BVALID | 13 | |
| W1 AW+W | 15 | adapter IDLE after W0 B-handshake |
| W1 BVALID | 18 | ST_WR_ISSU stalled 0 cy (NWP IDLE by then) |
| W2 AW+W | 20 | |
| W2 BVALID | 23 | |
| R0 AR | 25 | immediately after W2 B-handshake |
| R0 RVALID | 37 | rdata=0x1234_A5C3 MATCH |
| R1 AR | 39 | |
| R1 RVALID | 49 | rdata=0xDEAD_BEEF MATCH |
| R2 AR | 51 | |
| R2 RVALID | 61 | rdata=0xCAFE_5678 MATCH |

Conclusion: All 3 addresses written and read back correctly. ST_WR_ISSU and ST_RD_ISSU
serialization via `req_ready` prevents any data collision across adjacent transactions.
Address mapping (AXI addr >> 1) correct for all three addresses.

Status: **PASS** E006 (2026-06-21)

---

## Test 5 (M4): tb_axi_native_backpressure_smoke — E007

**Command:** `make test-axi-backpressure`

Full integration (same DUTs as M2). Tests BREADY and RREADY stall behavior through the
complete AXI→native→PHY→SDRAM chain. Injects concurrent AW+W/AR signals during stalls
to verify the adapter correctly blocks new requests while holding a response.

### B1 — BREADY stall

| Event | cyc | Result |
|-------|-----|--------|
| AXI AW+W | 12 | adapter IDLE, accepted |
| AXI BVALID | 13 | BREADY held 0 |
| Stall cy1 | 14 | bvalid=1 bresp=00 awready=0 wready=0 ✓ |
| Stall cy2 | 15 | bvalid=1 bresp=00 awready=0 wready=0 ✓ |
| Stall cy3 | 16 | bvalid=1 bresp=00 awready=0 wready=0 ✓ |
| BREADY released | 17 | write complete |

### B2 — normal write after BREADY release

| Event | cyc | Result |
|-------|-----|--------|
| AXI AW+W | 18 | adapter IDLE |
| AXI BVALID | 19 | BRESP=OKAY |

### R1 — RREADY stall

| Event | cyc | Result |
|-------|-----|--------|
| AXI AR | 21 | adapter IDLE, accepted |
| AXI RVALID | 33 | rdata=0x1234_A5C3, RREADY held 0 |
| Stall cy1 | 34 | rvalid=1 rresp=00 rdata=0x1234_A5C3 arready=0 ✓ |
| Stall cy2 | 35 | rvalid=1 rresp=00 rdata=0x1234_A5C3 arready=0 ✓ |
| Stall cy3 | 36 | rvalid=1 rresp=00 rdata=0x1234_A5C3 arready=0 ✓ |
| RREADY released | 37 | RDATA=0x1234_A5C3 MATCH |

### R2 — normal read after RREADY release

| Event | cyc | Result |
|-------|-----|--------|
| AXI AR | 38 | adapter IDLE |
| AXI RVALID | 48 | rdata=0xDEAD_BEEF MATCH |

Conclusion: Full-chain AXI backpressure PASS. BVALID/BRESP/AWREADY/WREADY stable during
BREADY stall (3/3 cycles each). RVALID/RRESP/RDATA/ARREADY stable during RREADY stall
(3/3 cycles each). No data corruption. Adapter correctly ignores injected AW+W/AR during
active response hold.

Status: **PASS** E007 (2026-06-21)

---

## Closeout (M5)

All planned tests E001-E007 executed and passed. sdram_test_04 is CLOSED.

| Test | TB | Result |
|------|----|--------|
| E001 | tb_axi_native_adapter_unit | PASS |
| E002 | tb_axi_native_adapter_protocol_unit | PASS |
| E003 | tb_axi_native_adapter_protocol_unit (assertion hardening) | PASS |
| E004 | tb_axi_native_single_write_read | PASS |
| E005 | tb_axi_native_raw_read_after_bvalid | PASS |
| E006 | tb_axi_native_multi_address_smoke | PASS |
| E007 | tb_axi_native_backpressure_smoke | PASS |

Bug (0xzzzz_1234 vs 0x1234_A5C3) NOT reproduced at AXI adapter layer.
Next: sdram_test_05 — Quartus synthesis + HW BIST @125 MHz.

