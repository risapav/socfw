# Imported from sdram_test_01

## Original bug

sdram_test_01 M7 found:

```
AXI 2-read path:
  expected rsp_rdata = 0x1234_A5C3
  got      rsp_rdata = 0xzzzz_1234
```

Upper halfword is Hi-Z. Lower halfword is correct.
Characteristic of a read assembly or handshake timing issue above the PHY.

## What was tried in sdram_test_01

- RSHIFT sweep: -1 too early (PRE-NBA, DQ=Z), 0 selected (stable capture)
- Single read PASS at PHY + scheduler level (RSHIFT=0)
- AXI 2-read FAIL: second halfword never arrives or arrives as Z

Root cause was not found in sdram_test_01.
Handed off to sdram_test_02 to isolate PHY layer.

## Ruling from sdram_test_02

PHY layer + 2x16 read + read_word_assembler all PASS (E007, E009, E010).
Bug is NOT in the PHY or assembler.

## Working hypothesis for sdram_test_04

Bug is in the AXI adapter / gearbox / handshake / backpressure path.
Candidates:
- AXI adapter state machine: misses second read request
- Address translation: off-by-one halfword address
- Backpressure: RREADY stall causes data to be dropped
- Race between native_rsp_valid and AXI RVALID

## W9825G6KH-6 parameters (fixed)

| Parameter | Value |
|-----------|-------|
| CAS latency | 3 |
| Burst length | 1 |
| Clock | 125 MHz |
| Interface | 16-bit |
