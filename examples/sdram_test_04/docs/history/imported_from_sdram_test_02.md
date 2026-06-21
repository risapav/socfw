# Imported from sdram_test_02

## sdram_test_02 proved

- RSHIFT=-1 too early: PHY captures DQ at PRE-NBA (Hi-Z). FAIL.
- RSHIFT=0 selected: PHY captures at sh=21, DQ stable since sh=20 post-NBA. PASS.
- RSHIFT=+1 also works but 1 cycle later than necessary.
- PHY + 2x16 read + read_word_assembler produced 32'h1234_A5C3. PASS (E007, E009, E010).
- The AXI 2-read failure from sdram_test_01 is NOT in the PHY or assembler layer.

## Key TB rule (D005 from sdram_test_02)

CMD_REG_ON_CLK_SH=1 adds 1 clk_sh cycle between TB driving CMD_WR and SDRAM model
processing it. DQ must be held valid for 1 extra CLK after CMD_WR.

In native_word_port: implemented as WR_LOW_HOLD and WR_HIGH_HOLD states.

## Configuration locked

| Setting | Value |
|---------|-------|
| READ_CAPTURE_SHIFT | 0 |
| CMD_REG_ON_CLK_SH | 1 |
