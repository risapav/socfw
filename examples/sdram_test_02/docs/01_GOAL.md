# docs/01_GOAL.md — Project Goal

## Problem statement

`sdram_test_01` shows a 3/6 regression failure with RSHIFT=0:

```
tb_axi_single_rw:   expected 0x1234a5c3, got 0xzzzz1234
tb_axi_burst_rw:    expected 0xdeadbeef, got 0xzzzzdead
tb_axi_backpressure: same pattern
```

The pattern `0xzzzz1234` means:
- low halfword (col=0): captured correctly (16'h1234 is col=1 data though...)
- high halfword (col=1): captured as Hi-Z

This indicates the PHY captures one halfword outside the valid DQ window.

## Questions this project must answer

1. Which clk_sh cycle contains the first valid DQ halfword after READ command?
2. Which clk_sh cycle contains the second valid DQ halfword (back-to-back reads)?
3. What is the correct READ_CAPTURE_SHIFT for the M0b model (cas_pipe[CL] = 3 stages)?
4. Is the failure in PHY capture, or in the word assembler/gearbox phase tracking?

## Scope

- PHY only (sdram_phy.sv + sdram_model_pro.sv)
- read_word_assembler.sv (new, minimal 16->32 bit assembler)
- No scheduler, no AXI, no BIST, no Quartus

## Known from sdram_test_01

- RSHIFT=-1: SIM FAIL 1/6 — race condition, PHY captures at T_cmd+4 = same cycle as model NBA
- RSHIFT=0:  SIM FAIL 3/6 — PHY/scheduler PASS, AXI path fails with 1-extra-cycle shift
- M0b model: cas_pipe[CL] (3 stages), DQ NBA at T_cmd+4 (1 cycle after SDRAM sees RD)
- Model has dq_drive_d for 1-cycle tOH hold

## Success criteria

RSHIFT=X where:
- tb_phy_single_read PASS
- tb_phy_back_to_back_reads PASS
- tb_read_32bit_word_timing PASS
