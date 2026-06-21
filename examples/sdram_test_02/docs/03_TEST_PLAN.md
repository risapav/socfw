# docs/03_TEST_PLAN.md — Test Plan

## Test 1: tb_read_word_assembler (M1 gate)

**Command:** `make test-assembler`

**What it tests:** read_word_assembler module in isolation.

**Inputs:**
- hw_valid=1, hw_first=1, hw_data=16'hA5C3
- hw_valid=1, hw_first=0, hw_data=16'h1234

**Expected output:** word_valid=1, word_data=32'h1234_A5C3

**Must pass before:** any PHY test is run.

---

## Test 2: tb_phy_single_read (M2 sweep)

**Command:** `make test-phy-single RSHIFT=<N>` or `make sweep-rshift`

**What it tests:** PHY + SDRAM model, single 16-bit write and read.

**Sequence:**
1. ACTIVE B0 R0
2. WRITE B0 C0 data=16'hA5C3
3. READ B0 C0
4. Monitor dq_i_valid + dq_i

**Expected:** dq_i=16'hA5C3 when dq_i_valid=1 (no Hi-Z, no wrong data)

**Record for every RSHIFT:** first cycle where dq_i_valid=1, actual dq_i value.

---

## Test 3: tb_phy_back_to_back_reads (M3)

**Command:** `make test-phy-back2back RSHIFT=<correct>`

**What it tests:** two consecutive 16-bit reads from col=0 and col=1.

**Sequence:**
1. ACTIVE B0 R0
2. WRITE B0 C0 data=16'hA5C3
3. WRITE B0 C1 data=16'h1234
4. READ B0 C0 (then immediately READ B0 C1)
5. Monitor: capture[0]=A5C3, capture[1]=1234

**Expected:** both captures correct, 1 cycle apart.

---

## Test 4: tb_read_32bit_word_timing (M4)

**Command:** `make test-word32 RSHIFT=<correct>`

**What it tests:** PHY + read_word_assembler, full 32-bit assembly.

**Expected:** word_valid=1, word_data=32'h1234_A5C3
