# docs/02_MILESTONES.md — Milestones

## M0 — Project setup and import from sdram_test_03

DoD:
- Directory structure created
- axi_native_adapter.sv created
- native_word_port.sv, sdram_build_cfg.svh copied from sdram_test_03
- Makefile with test-axi-unit target
- STATUS.md, docs/ populated
- History files created

Status: **COMPLETE** (project creation)

---

## M1 — AXI native adapter unit test with fake native backend

DoD:
- `make test-axi-unit` → *** PASS ***
- Log: `# BUILD_CONFIG PROJECT=sdram_test_04 RSHIFT=0 CMDREG=1`
- Verified: AXI write addr 0x00 → native_req_addr=0, native_req_wdata=0x1234_A5C3
- Verified: AXI read  addr 0x00 → RDATA=0x1234_A5C3
- Verified: AXI write addr 0x04 → native_req_addr=2, native_req_wdata=0xDEAD_BEEF
- Verified: AXI read  addr 0x04 → RDATA=0xDEAD_BEEF
- No SDRAM PHY. No SDRAM model. Fake native backend only.

Status: **COMPLETE / PASS** — E001 (2026-06-21)

---

## M1b — AXI protocol guard unit test

DoD:
- `make test-axi-unit` → *** PASS *** (regression, E001 unchanged)
- `make test-axi-protocol` → *** PASS ***
- P1: AW-then-W separated, BRESP=OKAY, wdata=0x1234_A5C3
- P2: W-then-AW separated, BRESP=OKAY, wdata=0xDEAD_BEEF
- P3: native_req_ready stall 3 cy, BRESP=OKAY
- P4: BREADY stall 3 cy, BRESP=OKAY
- P5: RREADY stall 3 cy, RRESP=OKAY, RDATA stable
- E1: AWADDR[1:0]≠00 → no native_req, BRESP=SLVERR
- E2: WSTRB≠4'b1111 → no native_req, BRESP=SLVERR
- E3: ARADDR[1:0]≠00 → no native_req, RRESP=SLVERR, RDATA=0

Status: **COMPLETE / PASS** — E002 (2026-06-21)

---

## M1c — AXI assertion hardening

DoD:
- `make test-axi-unit` → *** PASS *** (regression, E001 unchanged)
- `make test-axi-protocol` → *** PASS *** (E003, no RTL change)
- P3: native_req_valid/write/addr/wdata verified stable across all 3 stall cycles
- P4: s_axi_bvalid/bresp stable + awready=0/wready=0 verified across 3 stall cycles
  (AWVALID+WVALID injected during stall, adapter correctly ignores them)
- P5: s_axi_rvalid/rresp/rdata stable + arready=0 verified across 3 stall cycles
  (ARVALID injected during stall, adapter correctly ignores it)
- E1: native_req_valid=0 + bvalid=1 + bresp=SLVERR held for 2 cycles
- E2: native_req_valid=0 + bvalid=1 + bresp=SLVERR held for 2 cycles
- E3: native_req_valid=0 + rvalid=1 + rresp=SLVERR + rdata=0 held for 2 cycles
- RTL unchanged (axi_native_adapter.sv not modified)

Status: **COMPLETE / PASS** — E003 (2026-06-21)

---

## M2 — AXI adapter + native_word_port + PHY + SDRAM model single write/read

DoD:
- AXI write 0x1234_A5C3 at AXI addr 0x00, read back, rdata=0x1234_A5C3
- Instantiates: axi_native_adapter + native_word_port + sdram_phy + sdram_model_pro
- AXI-lite bridge replaces fake native backend

Status: **COMPLETE / PASS** — E004 (2026-06-21)

---

## M2b — AXI raw read-after-BVALID hazard check

DoD:
- BVALID observed before native write completion (cyc=13 vs cyc=19)
- AR issued immediately after BVALID accepted (cyc=15), no manual native_req_ready wait
- No tWR gap inserted by testbench
- RDATA returned 0x1234_A5C3 (MATCH)
- Conclusion: early BVALID does not corrupt immediate read-after-write in current
  single-slave model — native_word_port serializes read behind the active write
  via req_ready (ST_RD_ISSU stalls until NWP returns to IDLE)

Status: **COMPLETE / PASS** — E005 (2026-06-21)

---

## M3 — AXI multi-address smoke

DoD:
- Write and read back at AXI addrs 0x00, 0x04, 0x08
- All reads return correct data
- Address mapping verified end-to-end

Verified:
- W0 addr=0x00 wdata=0x1234_A5C3: BVALID cyc=13
- W1 addr=0x04 wdata=0xDEAD_BEEF: BVALID cyc=18
- W2 addr=0x08 wdata=0xCAFE_5678: BVALID cyc=23
- R0 addr=0x00: RDATA=0x1234_A5C3 MATCH (cyc=37)
- R1 addr=0x04: RDATA=0xDEAD_BEEF MATCH (cyc=49)
- R2 addr=0x08: RDATA=0xCAFE_5678 MATCH (cyc=61)
- AXI_ADDR_0/4/8_RESULT=PASS, errors=0

Status: **COMPLETE / PASS** — E006 (2026-06-21)

---

## M4 — AXI backpressure smoke

DoD:
- Test AXI backpressure: delay BREADY and RREADY
- Verify adapter handles stalls correctly
- No data corruption during stalled cycles

Verified:
- B1 (BREADY stall): BVALID cyc=13, 3-cycle stall (cy14-16)
  - BVALID stable 3/3, BRESP=00 3/3, AWREADY=0 3/3, WREADY=0 3/3
  - BREADY released cyc=17, write complete
- B2 (normal write ADDR4): BVALID cyc=19
- R1 (RREADY stall): AR cyc=21, RVALID cyc=33, 3-cycle stall (cy34-36)
  - RVALID stable 3/3, RRESP=00 3/3, RDATA=0x1234_A5C3 3/3, ARREADY=0 3/3
  - RREADY released cyc=37, RDATA=0x1234_A5C3 MATCH
- R2 (normal read ADDR4): RVALID cyc=48, RDATA=0xDEAD_BEEF MATCH
- BREADY_STALL_RESULT=PASS, RREADY_STALL_RESULT=PASS
- ADDR0_RDATA_RESULT=PASS, ADDR4_RDATA_RESULT=PASS, errors=0

Status: **COMPLETE / PASS** — E007 (2026-06-21)

---

## M5 — Closeout and handoff

DoD:
- All M1-M4 PASS or failure class documented
- AXI bug root cause identified or clearly scoped
- STATUS.md marked COMPLETE
- Conclusions documented

Status: **COMPLETE / PASS** — E007 (2026-06-21)

sdram_test_04 is closed after M5. Further hardware validation belongs to sdram_test_05.
