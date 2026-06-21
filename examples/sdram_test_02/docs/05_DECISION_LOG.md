# docs/05_DECISION_LOG.md — Decision Log

| ID | Date | Decision | Rationale |
|----|------|----------|-----------|
| D001 | 2026-06-21 | Project scope: sim only, no Quartus, no HW | Isolate timing problem without synthesis variables |
| D002 | 2026-06-21 | CL=3 fixed, CMDREG=1 fixed | Same as sdram_test_01 baseline, only RSHIFT swept |
| D003 | 2026-06-21 | No AXI, no scheduler in this project | Minimize complexity; find PHY timing first |
| D004 | 2026-06-21 | board.yaml owned exclusively by user | Per CLAUDE.md rule, never touch board.yaml |
| D005 | 2026-06-21 | TB WRITE must hold dq_oe=1 one extra CLK after CMD_WR | CMD_REG_ON_CLK_SH=1 delays WRITE cmd by 1 clk_sh; model processes at sh=M+1 and reads DQ combinatorially — dq_oe must still be asserted then |
| D006 | 2026-06-21 | Use READ_CAPTURE_SHIFT=0 and CMD_REG_ON_CLK_SH=1 as the selected simulation candidate for next native-core integration step | RSHIFT=0 is the minimum safe capture point: captures DQ 1 sh-cycle after it stabilises. RSHIFT=-1 captures too early (PRE-NBA = Hi-Z). RSHIFT=+1 also passes but adds unnecessary latency. |
