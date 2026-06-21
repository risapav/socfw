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

