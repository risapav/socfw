# docs/04_EXPERIMENT_LOG.md — Experiment Log

## Rules

- Every sim run = one entry.
- Never remove entries. Failed experiments are essential data.
- Missing value = —

## Experiment table

| ID | Date | Test | RSHIFT | CMDREG | Result | actual | expected | conclusion |
|----|------|------|-------:|--------|--------|--------|----------|------------|
| E001 | 2026-06-21 | tb_axi_native_adapter_unit | 0 | 1 | **PASS** | wr_addr0: native_addr=0 wdata=0x1234_A5C3; rd_addr0: RDATA=0x1234_A5C3; wr_addr4: native_addr=2 wdata=0xDEAD_BEEF; rd_addr4: RDATA=0xDEAD_BEEF | all match | AXI→native addr conversion correct (>>1). AXI-lite W+B+R handshake correct. 20 checks PASS, 0 errors, 0 warnings. |
| E002 | 2026-06-21 | tb_axi_native_adapter_protocol_unit | 0 | 1 | **PASS** | P1:bresp=OKAY wdata=0x1234_A5C3; P2:bresp=OKAY wdata=0xDEAD_BEEF; P3:bresp=OKAY (stall 3cy); P4:bresp=OKAY (bready stall); P5:rresp=OKAY rdata=0x5A5A_A5A5 (rready stall); E1:bresp=SLVERR (unaligned wr); E2:bresp=SLVERR (partial wstrb); E3:rresp=SLVERR rdata=0 (unaligned rd) | all match | Protocol guards correct: SLVERR for unaligned addr and partial WSTRB. Stall handling correct on all channels. 11 checks PASS, 0 errors, 0 warnings. |
| E003 | 2026-06-21 | tb_axi_native_adapter_protocol_unit | 0 | 1 | **PASS** | P3: req_valid/write/addr/wdata stable cy1-3; P4: bvalid/bresp stable, awready=0/wready=0 cy1-3 (AW+W injected during stall); P5: rvalid/rresp/rdata stable, arready=0 cy1-3 (AR injected during stall); E1/E2: no_req + bvalid + SLVERR cy1-2; E3: no_req + rvalid + SLVERR + rdata=0 cy1-2 | all 54 checks match | Assertion hardening PASS. No RTL change needed. Stall stability and SLVERR isolation both proven cycle-by-cycle. |
