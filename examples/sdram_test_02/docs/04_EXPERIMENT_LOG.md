# docs/04_EXPERIMENT_LOG.md — Experiment Log

## Rules

- Every sim run = one entry.
- Never remove entries. Failed experiments are essential data.
- Missing value = `—`

## Experiment table

| ID | Date | Test | RSHIFT | CMDREG | Result | actual | expected | conclusion |
|----|------|------|-------:|--------|--------|--------|----------|------------|
| E001 | 2026-06-21 | tb_read_word_assembler | N/A | N/A | **PASS** | word=0x1234_A5C3 | 0x1234_A5C3 | Unit test OK. assembler combines low=A5C3+high=1234 → 32h1234_A5C3 ✓ |
| E002 | 2026-06-21 | make clean + test-assembler | N/A | N/A | **PASS** | word=0x1234_A5C3 | 0x1234_A5C3 | M2a log naming fix verified — clean build + assembler still passes. |
| E003 | 2026-06-21 | tb_phy_single_read (sweep) | -1 | 1 | **FAIL** | dq_i=0xzzzz @ cyc=20 | 0xa5c3 | TB WRITE timing bug: dq_oe released before model processes WRITE (CMD FF +1 clk_sh lag). Memory stores Z. |
| E004 | 2026-06-21 | tb_phy_single_read (sweep) | 0 | 1 | **FAIL** | dq_i=0xzzzz @ cyc=21 | 0xa5c3 | Same root cause as E003. RSHIFT shift in capture cycle (+1 vs E003) confirms RSHIFT works, but memory=Z. |
| E005 | 2026-06-21 | tb_phy_single_read (sweep) | +1 | 1 | **FAIL** | dq_i=0xzzzz @ cyc=22 | 0xa5c3 | Same root cause as E003. All 3 RSHIFT values fail identically. TB fix required: hold dq_oe=1 one extra CLK after CMD_WR. |
| E006 | 2026-06-21 | tb_phy_single_read (sweep, TB dq_oe fix) | -1 | 1 | **FAIL** | dq_i=0xzzzz @ cyc=20 | 0xa5c3 | READ_IDX=2 → PHY captures DQ at sh=20. Model drives DQ via NBA at sh=19 (CL+1 pipeline), visible at sh=20 post-posedge. PRE-NBA capture = Z. Timing boundary — expected. |
| E007 | 2026-06-21 | tb_phy_single_read (sweep, TB dq_oe fix) | 0 | 1 | **PASS** | dq_i=0xa5c3 @ cyc=21 | 0xa5c3 | READ_IDX=3 → PHY captures at sh=21 (DQ stable since sh=20 post-NBA). PASS ✓ |
| E008 | 2026-06-21 | tb_phy_single_read (sweep, TB dq_oe fix) | +1 | 1 | **PASS** | dq_i=0xa5c3 @ cyc=22 | 0xa5c3 | READ_IDX=4 → PHY captures at sh=22 (2 cycles after DQ stable). PASS ✓ |
| E009 | 2026-06-21 | tb_phy_back_to_back_reads | 0 | 1 | **PASS** | cap[0]=0xa5c3 @ cyc=24, cap[1]=0x1234 @ cyc=25 | 0xa5c3, 0x1234 | Both halfwords MATCH. Cycle gap=1 (consecutive). Back-to-back read path verified ✓ |
| E010 | 2026-06-21 | tb_read_32bit_word_timing | 0 | 1 | **PASS** | word_data=0x1234_A5C3 @ cyc=25 | 0x1234_A5C3 | dq_i_valid: cyc=23 (hw0=A5C3), cyc=24 (hw1=1234). word_valid @ cyc=25. PHY+assembler full 32-bit path PASS ✓ |

