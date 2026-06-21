# STATUS.md — sdram_test_03

| Field | Value |
|-------|-------|
| Project | sdram_test_03 |
| Purpose | Native 32-bit SDRAM read/write core integration (sim only) |
| Current milestone | M4 — COMPLETE |
| Final result | **PASS** |
| Selected config | RSHIFT=0, CMDREG=1 |
| Closed | 2026-06-21 |

---

## Conclusion

Native 32-bit SDRAM write/read path works in simulation through:

```
native_word_port -> sdram_phy -> sdram_model_pro
```

Verified:
- Single 32-bit write/read at halfword base addr 0 (E002)
- Three 32-bit write/read operations at halfword base addr 0, 2, 4 (E003)
- 32-bit data assembly order: {high, low} = {wdata[31:16], wdata[15:0]}
- req_addr semantic: halfword base address (word occupies req_addr and req_addr+1)

Remaining issue from sdram_test_01:
The AXI 2-read bug (0xzzzz1234) is above the native port layer — likely in the AXI adapter, gearbox, handshake, or backpressure path.

Next project: sdram_test_04 — AXI adapter over proven native_word_port.

---

## Experiment results

| ID | Test | Result | Key data |
|----|------|--------|----------|
| E001 | tb_native_word_port_unit | PASS | rsp_rdata=0x1234_A5C3 @ cyc=18 |
| E002 | tb_native_single_write_read | PASS | rsp_rdata=0x1234_A5C3 @ cyc=28 |
| E003 | tb_native_multi_address_smoke | PASS | RD[0]=0x1234_A5C3@cyc=44, RD[1]=0xDEAD_BEEF@cyc=53, RD[2]=0xCAFE_5678@cyc=62 |

---

## Inherited baseline (sdram_test_02)

| Setting | Value | Source |
|---------|-------|--------|
| READ_CAPTURE_SHIFT | 0 | sdram_test_02 E007 PASS |
| CMD_REG_ON_CLK_SH | 1 | sdram_test_02 fixed config |
| TB write hold | +1 CLK after CMD_WR | sdram_test_02 D005 |

---

## Not allowed (closed project — do not extend)

- Quartus / HW / board.yaml
- AXI, scheduler, BIST
- XFCP integration
- Any new RTL or testbench additions

Further AXI integration belongs to sdram_test_04.
