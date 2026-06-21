# Imported from sdram_test_03

## sdram_test_03 proved

- native_word_port unit test PASS (E001): write generates 2x CMD_WR sub-commands,
  fake phy_rvalid injection assembles 32'h1234_A5C3 correctly.
- native single write/read PASS (E002): native_word_port + sdram_phy + sdram_model_pro,
  write 32'h1234_A5C3 at addr 0, read back = 32'h1234_A5C3.
- native multi-address PASS (E003): 3x write/read at halfword base addr 0, 2, 4,
  all data correct.

## Address semantics (D006 from sdram_test_03)

native_word_port req_addr is a HALFWORD base address.
A 32-bit word uses req_addr (low halfword) and req_addr+1 (high halfword).
Non-overlapping 32-bit words must use even native addresses: 0, 2, 4, ...

## AXI to native address conversion

AXI uses byte addressing. native_word_port uses halfword addressing.

```
AXI byte addr 0x00000000 -> native halfword base addr 0
AXI byte addr 0x00000004 -> native halfword base addr 2
AXI byte addr 0x00000008 -> native halfword base addr 4
formula: native_req_addr = axi_addr >> 1
```

Word-aligned AXI addresses only (axi_addr[1:0] == 2'b00).

## Key module: native_word_port.sv

Copied unmodified from sdram_test_03.
State machine: IDLE -> WR_LOW -> WR_LOW_HOLD -> WR_HIGH -> WR_HIGH_HOLD -> IDLE (write)
               IDLE -> RD_LOW -> RD_HIGH -> RD_WAIT -> IDLE (read, 2x phy_rvalid)
req_ready = (state == IDLE). req_ready goes LOW when request accepted.

## AXI bug from sdram_test_01 is confirmed NOT in native layer

The bug (0xzzzz_1234) is above native_word_port. Investigation was continued
in sdram_test_04 at the AXI adapter level.

## sdram_test_04 conclusion (2026-06-21)

The AXI adapter layer is clean. E001-E007 cover:
- AXI write/read positive path (unit + fake backend)
- Protocol guards (unaligned addr, partial WSTRB -> SLVERR)
- AW/W separated handshake (AW-first, W-first)
- native_req_ready stall
- Full integration: AXI->NWP->PHY->SDRAM model single write/read
- Immediate read-after-BVALID (early BVALID hazard, no corruption)
- Multi-address 3xW + 3xR at AXI 0x00/0x04/0x08, all MATCH
- Full-chain BREADY and RREADY backpressure, BVALID/RVALID/RDATA stable

The bug (0xzzzz_1234 vs 0x1234_A5C3) was NOT reproduced in simulation at the
AXI adapter layer. It likely manifests only in hardware (capture timing, I/O
delays, or board-level signal integrity). Investigation continues in sdram_test_05
with Quartus synthesis + HW BIST @125 MHz.
