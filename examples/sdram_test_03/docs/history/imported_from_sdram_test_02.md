# Imported from sdram_test_02

## Context

sdram_test_03 was created 2026-06-21 after sdram_test_02 closed with M4 PASS.

## sdram_test_02 proved

- RSHIFT=-1 too early: PHY captures DQ at same sh-cycle model's NBA fires (PRE-NBA = Hi-Z). FAIL.
- RSHIFT=0 selected: PHY captures at sh=21, DQ stable since sh=20 post-NBA. PASS.
- RSHIFT=+1 also works but captures 1 cycle later than necessary.
- PHY + 2×16 read + read_word_assembler produced 32'h1234_A5C3. PASS (E007, E009, E010).
- The AXI 2-read failure from sdram_test_01 is NOT in the PHY or assembler layer.

## Key TB rule (D005 from sdram_test_02)

CMD_REG_ON_CLK_SH=1 adds 1 clk_sh cycle between TB driving CMD_WR and SDRAM model
processing it. DQ must be held valid for 1 extra CLK after CMD_WR.

In native_word_port: implemented as WR_LOW_HOLD and WR_HIGH_HOLD states.

## Imported files

| File | Source | Note |
|------|--------|------|
| rtl/sdram/sdram_pkg.sv | sdram_test_02/rtl/sdram/ | Unmodified |
| rtl/sdram/sdram_phy.sv | sdram_test_02/rtl/sdram/ | Unmodified (M0b version) |
| rtl/sdram/sdram_build_cfg.svh | sdram_test_02/rtl/sdram/ | Regenerated: RSHIFT=0 |
| rtl/sdram/read_word_assembler.sv | sdram_test_02/rtl/sdram/ | Unmodified |
| sim/model/sdram_model_pro.sv | sdram_test_02/sim/model/ | Unmodified (M0b version) |

## NOT imported

- AXI files
- Quartus project files
- BIST, scheduler, bank machines
- Old Questa work/

## sdram_test_03 outcome

sdram_test_03 confirmed that the result from sdram_test_02 scales to a simple native 32-bit word port.
The selected config remains RSHIFT=0, CMDREG=1.

M1-M3 all PASS. native_word_port drives correct 2×16 sub-commands for both writes and reads.
Multi-address smoke test (addr 0, 2, 4) verified address mapping is correct (E003).
