# docs/04_EXPERIMENT_LOG.md — Experiment Log

## Rules

- Every sim run = one entry.
- Never remove entries. Failed experiments are essential data.
- Missing value = `—`

## Experiment table

| ID | Date | Test | RSHIFT | CMDREG | Result | actual | expected | conclusion |
|----|------|------|-------:|--------|--------|--------|----------|------------|
| E001 | 2026-06-21 | tb_native_word_port_unit | 0 | 1 | **PASS** | rsp_rdata=0x1234_A5C3 @ cyc=18 | 0x1234_A5C3 | Write[0]=A5C3@addr0, Write[1]=1234@addr1. Read assembled correctly. WR_HOLD states confirmed. |
| E002 | 2026-06-21 | tb_native_single_write_read | 0 | 1 | **PASS** | rsp_rdata=0x1234_A5C3 @ cyc=28 | 0x1234_A5C3 | WR_LOW@sh=13, WR_HIGH@sh=15, RD_LOW@sh=21, RD_HIGH@sh=22, dq_i_v low@sh=26, high@sh=27. Full native path verified ✓ |
| E003 | 2026-06-21 | tb_native_multi_address_smoke | 0 | 1 | **PASS** | RD[0]=0x1234_A5C3@cyc=44, RD[1]=0xDEAD_BEEF@cyc=53, RD[2]=0xCAFE_5678@cyc=62 | all 3 MATCH | 3 x 32-bit write+read at halfword base addr 0,2,4. All match. Address mapping correct. 0 errors. |
