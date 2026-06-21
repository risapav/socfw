# docs/05_DECISION_LOG.md — Decision Log

| ID | Date | Decision | Rationale |
|----|------|----------|-----------|
| D001 | 2026-06-21 | Project scope: sim only, no Quartus, no HW | Isolate native core integration without synthesis variables |
| D002 | 2026-06-21 | RSHIFT=0, CMDREG=1 fixed (inherited from sdram_test_02) | Minimum safe capture point proven by sdram_test_02 sweep |
| D003 | 2026-06-21 | No AXI in this project | Add AXI adapter in sdram_test_04 after native core is proven |
| D004 | 2026-06-21 | board.yaml owned exclusively by user | Per CLAUDE.md rule, never touch board.yaml |
| D005 | 2026-06-21 | native_word_port adds WR_x_HOLD states (1 CLK dq_oe extension per CMD_WR) | CMD_REG_ON_CLK_SH=1 delays WRITE by 1 clk_sh; model reads DQ at sh=M+1 — inherited from sdram_test_02 D005 |
| D006 | 2026-06-21 | req_addr = halfword base address; 32-bit word uses req_addr and req_addr+1 | native_word_port drives phy_cmd_addr and phy_cmd_addr+1 for low/high halfwords. Users must use even non-overlapping bases (0, 2, 4, ...). Verified by E003 (addr 0,2,4 all PASS). |
| D007 | 2026-06-21 | Close sdram_test_03 after native multi-address PASS; next layer is AXI adapter in sdram_test_04 | PHY capture, 2×16 assembly, native single R/W, and native multi-address R/W are all proven in simulation. The remaining failure class from sdram_test_01 (0xzzzz1234 read bug) is above the native port layer. |
