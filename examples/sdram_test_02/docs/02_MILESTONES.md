# docs/02_MILESTONES.md — Milestones

## M1 — Assembler unit test — PASS ✓

DoD:
- `make test-assembler` → *** PASS ***
- Log starts with correct BUILD_CONFIG header
- docs/04_EXPERIMENT_LOG.md updated

Result: E001, E002 — PASS (2026-06-21)

---

## M2 — PHY single read timing sweep — PASS ✓

DoD:
- `make sweep-rshift` run for RSHIFT=-1, 0, +1
- For each: log saved, cycle number of dq_i_valid recorded
- PASS/FAIL and actual dq_i value recorded for each
- Correct RSHIFT identified (where dq_i === expected and no Hi-Z)

Result: E006-E008 — RSHIFT=0 and RSHIFT=+1 PASS; RSHIFT=-1 FAIL (expected: 1 cycle early). Selected: RSHIFT=0. (2026-06-21)

---

## M3 — PHY back-to-back reads — PASS ✓

DoD:
- Two consecutive reads return correct A5C3 and 1234 in correct order
- Cycle gap between captures matches expected (1 clk cycle)
- `make test-phy-back2back RSHIFT=<correct>` → *** PASS ***

Result: E009 — cap[0]=0xA5C3 @ cyc=24, cap[1]=0x1234 @ cyc=25, gap=1. PASS (2026-06-21)

---

## M4 — 32-bit word assembly — PASS ✓ — COMPLETE

DoD:
- `make test-word32 RSHIFT=<correct>` → *** PASS ***
- word_data == 32'h1234_A5C3
- STATUS.md updated with findings

Result: E010 — word_data=0x1234_A5C3 @ cyc=25. PASS (2026-06-21)

---

## sdram_test_02 is closed after M4.

Further integration belongs to sdram_test_03.

---

## Out of scope (never implemented here)

- AXI integration
- Quartus / HW
- BIST, scheduler
- XFCP
