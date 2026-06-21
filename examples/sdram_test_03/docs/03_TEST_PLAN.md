# docs/03_TEST_PLAN.md — Test Plan

## Fixed configuration

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| READ_CAPTURE_SHIFT | 0 | sdram_test_02 M2 sweep: minimum safe point |
| CMD_REG_ON_CLK_SH | 1 | Same as sdram_test_01/02 baseline |
| CAS_LATENCY | 3 | W9825G6KH-6 at 125 MHz |

## Test 1: tb_native_word_port_unit (M1)

**Command:** `make test-native-unit`

No PHY. No SDRAM model. Fake phy_cmd_ready=1. Inject fake phy_rvalid.

Test A — Write:
- Drive req_valid=1, req_write=1, addr=0, wdata=32'h1234_A5C3
- Verify PHY sub-commands: WRITE addr=0 data=0xA5C3, then WRITE addr=1 data=0x1234

Test B — Read:
- Drive req_valid=1, req_write=0, addr=0
- Inject phy_rvalid=1 with rdata=0xA5C3, then rdata=0x1234
- Verify rsp_valid=1 and rsp_rdata=32'h1234_A5C3

## Test 2: tb_native_single_write_read (M2)

**Command:** `make test-native-single`

native_word_port + sdram_phy + sdram_model_pro.

Sequence:
1. Reset + ACTIVE B0 R0
2. native WRITE addr=0 wdata=32'h1234_A5C3
3. tWR wait
4. native READ addr=0
5. Verify rsp_rdata=32'h1234_A5C3

Timing notes:
- native_word_port uses WR_x_HOLD states: 1 extra CLK after CMD_WR (D005)
- RSHIFT=0: PHY captures DQ at sh=21 (1 cycle after model NBA at sh=20)

## Test 3: tb_native_multi_address_smoke (M3)

**Command:** `make test-native-multi`

native_word_port + sdram_phy + sdram_model_pro.

Sequence:
1. Reset + ACTIVE B0 R0
2. native WRITE addr=0 wdata=32'h1234_A5C3, wait req_ready, 2-cycle gap
3. native WRITE addr=2 wdata=32'hDEAD_BEEF, wait req_ready, 2-cycle gap
4. native WRITE addr=4 wdata=32'hCAFE_5678, wait req_ready, 2-cycle gap
5. native READ addr=0, verify rsp_rdata=32'h1234_A5C3
6. native READ addr=2, verify rsp_rdata=32'hDEAD_BEEF
7. native READ addr=4, verify rsp_rdata=32'hCAFE_5678

Address rule: req_addr = halfword base address. 32-bit word occupies req_addr and req_addr+1.
Even non-overlapping bases (0, 2, 4, ...) required.
