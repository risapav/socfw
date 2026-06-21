# docs/02_MILESTONES.md — Milestones

## M0 — Project setup and import from sdram_test_02

DoD:
- Directory structure created
- sdram_pkg.sv, sdram_phy.sv, read_word_assembler.sv, sdram_model_pro.sv copied
- native_word_port.sv created
- Makefile with test-native-unit and test-native-single
- STATUS.md, docs/ populated
- sdram_build_cfg.svh: RSHIFT=0, CMDREG=1

Status: **COMPLETE** (project creation)

---

## M1 — native_word_port unit test

DoD:
- `make test-native-unit` → *** PASS ***
- Log: `# BUILD_CONFIG PROJECT=sdram_test_03 RSHIFT=0 CMDREG=1`
- Verified: write generates sub-commands low(addr+0, A5C3) then high(addr+1, 1234)
- Verified: inject fake phy_rvalid → rsp_rdata=32'h1234_A5C3

Status: **COMPLETE / PASS** — E001 (2026-06-21)

---

## M2 — native single write/read through PHY + SDRAM model

DoD:
- `make test-native-single` → *** PASS ***
- native_word_port + sdram_phy + sdram_model_pro
- write 32'h1234_A5C3 at addr 0, read back, rdata=32'h1234_A5C3
- All cycle numbers logged

Status: **COMPLETE / PASS** — E002 (2026-06-21)

---

## M3 — native multi-address smoke test

DoD:
- Write and read back at halfword base addr 0, 2, 4 to verify address mapping
- All reads return correct data

Status: **COMPLETE / PASS** — E003 (2026-06-21)

---

## M4 — closeout and handoff to sdram_test_04 AXI adapter

DoD:
- All M1-M3 PASS
- Conclusions documented
- STATUS.md marked COMPLETE
- sdram_test_04 scope defined

Status: **COMPLETE / PASS** (2026-06-21)

---

sdram_test_03 is closed after M4.
Further AXI integration belongs to sdram_test_04.
