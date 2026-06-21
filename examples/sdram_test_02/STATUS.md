# STATUS.md — sdram_test_02

| Field | Value |
|-------|-------|
| Project | sdram_test_02 |
| Purpose | SDRAM read path timing laboratory (sim only) |
| Current milestone | M4 — COMPLETE |
| Final result | **PASS** |
| Selected configuration | RSHIFT=0, CMDREG=1 |
| Closed | 2026-06-21 |

---

## Conclusion

PHY read capture and simple 2×16→32 assembly are correct in isolation.

- RSHIFT=-1: captures DQ at the same sh-cycle the model NBA sets it — reads PRE-NBA (Hi-Z). Too early.
- RSHIFT=0: captures 1 sh-cycle after DQ is stable. Minimum safe setting. **Selected.**
- RSHIFT=+1: captures 2 sh-cycles after DQ stable. Also passes but adds unnecessary latency.

The isolated PHY+assembler path is not the source of the AXI failure seen in sdram_test_01.
The remaining bug is likely above the raw PHY+assembler layer (scheduler, read engine, or AXI gearbox).

---

## Sweep result (E006-E008, 2026-06-21)

| RSHIFT | READ_IDX | DQ appears | PHY captures | Result |
|-------:|:--------:|:----------:|:------------:|:------:|
| -1 | 2 | sh=20 (post-NBA) | sh=20 posedge (PRE-NBA) | **FAIL** — 1 cycle early |
| 0 | 3 | sh=20 (post-NBA) | sh=21 posedge | **PASS** ✓ |
| +1 | 4 | sh=20 (post-NBA) | sh=22 posedge | **PASS** ✓ |

---

## Not allowed

- Quartus / HW / board.yaml
- AXI, scheduler, BIST
- XFCP integration
- Do not extend sdram_test_02 further — project is closed

---

## Next project

`sdram_test_03` — native SDRAM read/write core integration.
Further integration (AXI, scheduler, BIST) belongs to sdram_test_03, not here.
