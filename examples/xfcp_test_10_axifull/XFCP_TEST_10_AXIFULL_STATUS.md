# xfcp_test_10_axifull — Status

## Stav: Faza B UZAVRETA (2026-06-15)

Sim regression T01–T37 **ALL PASS**. RTL kompletny.

---

## Fazy

| Faza | Popis                        | Stav       |
|------|------------------------------|------------|
| A    | RTL — MEM backend (AXI-Full) | UZAVRETA   |
| B    | Sim — T01–T37 regression     | UZAVRETA   |
| C    | Quartus build + timing       | TODO       |
| D    | HW regression (Python tools) | TODO       |
| E    | Python MEM tools             | TODO       |

---

## RTL — nove moduly

### `rtl/xfcp/xfcp_mem_adapter.sv`
AXI4-Full master pre XFCP MEM backend.
- `MEM_READ (0x30)`: AXI AR + R burst, odpoved RESP_MEM_READ (0x32)
- `MEM_WRITE (0x31)`: AXI AW + W burst, odpoved RESP_MEM_WRITE (0x33)
- Parametre: `MAX_BYTES=256`, `DATA_WIDTH=32`, `ADDR_WIDTH=32`
- rfifo: 64-entry (BEATS_MAX) kruhovy buffer pre AXI R beat-y
- Timeout: 4096 cyklov, pocita len ked AXI slave nereaguje (nie ked caka na UART payload)

### `rtl/axifull_sram.sv`
AXI4-Full slave, 256x32b SRAM.
- WR FSM: WR_IDLE → WR_DATA → WR_RESP
- RD FSM: RD_IDLE → RD_DATA → RD_WAIT (1-cycle read latency)
- Burst: INCR, max 64 beatov (256B)

### `rtl/xfcp/xfcp_pkg.sv` (rozsireny)
Nove opkody:
```
XFCP_OP_MEM_READ    = 8'h30
XFCP_OP_MEM_WRITE   = 8'h31
XFCP_OP_RESP_MEM_READ  = 8'h32
XFCP_OP_RESP_MEM_WRITE = 8'h33
```

---

## Opravene bugy (Faza B)

### Bug 1: `xfcp_arbiter_2to1.sv` — p0_is_write_w nezahrnoval MEM_WRITE
- **Symptom**: MEM_WRITE paket dostal synteticke TLAST na poslednom hlavickovom bajte
  → parser padal do S_DROP stavu
- **Fix**: `p0_is_write_w` rozsireny o `XFCP_OP_MEM_WRITE`

### Bug 2: `xfcp_fabric_endpoint.sv` — MEM_WRITE wdata tiekla do AXIL buffra
- **Symptom**: `g_engine[0].i_engine.i_write_buffer: FIFO OVERFLOW! count=32 DEPTH=32`
- **Fix**: `write_data_valid` pre AXIL engine doplneny o `&& !wdata_stage_is_mem_r`

### Bug 3: `xfcp_mem_adapter.sv` — rfifo deadlock pre burst > 2 beaty
- **Symptom**: MEM_READ count=16 (4 beaty) timeout v ST_R; count=4 (1 beat) fungoval
- **Pricina**: rfifo mal 2 sloty → po 2 beatoch full → m_axi_rready=0 → SRAM zaseknuty
  v RD_WAIT → nikdy nenaslal rlast → adapter nevsiel do ST_DATA → rfifo nikdy nevyprazdnil
  → kruhovy deadlock
- **Fix**: rfifo rozsirensy na BEATS_MAX=64 zaznamov s RFIFO_AW-bitovymi pointermi

### Bug 4: `xfcp_mem_adapter.sv` — ST_AW_W timeout behal aj pri cakani na UART payload
- **Symptom**: MEM_WRITE status=0x06 (TIMEOUT) po 1024 cykloch; UART pri 115200 baud
  dorucuje 4B payload za ~34720 cyklov
- **Fix**: to_cnt_q sa nuluje ked `!mem_wdata_valid_i` (cakame na upstream, nie chyba slave)

---

## Sim regression (T01–T37)

```
T01-T10:  AXIL READ/WRITE (1B, 4B, burst)
T11-T20:  STATUS, CAPS, TARGET INFO, AXIS loopback
T21-T30:  Multi-target AXIL (eng0+eng1)
T31-T37:  MEM READ/WRITE (roz. dlzky, burst, boundary)
```

Vysledok: **XFCP_TEST_10_AXIFULL REGRESSION PASSED** (37/37)

---

## Architektura (top)

```
UART ─► xfcp_arbiter_2to1 ─► xfcp_fabric_endpoint ─► xfcp_axi_engine[0] ─► axil_regfile
ETH  ─►                   ─►                       ─► xfcp_axi_engine[1] ─► axil_sys_ctrl
                                                    ─► xfcp_axis_adapter
                                                    ─► xfcp_caps_adapter
                                                    ─► xfcp_target_info_adapter
                                                    ─► xfcp_mem_adapter ──► axifull_sram
```

---

## Nasledujuce kroky (Faza C+)

1. **Faza C**: `project.yaml` + `ip/xfcp_test_10_axifull_top.ip.yaml` update, Quartus build
2. **Faza D**: HW regression — `tools/test_hw.py` s MEM testami
3. **Faza E**: Python MEM tools — `tools/xfcp/protocol.py` (encode/decode MEM), `tools/xfcp/bus.py` (mem_read/mem_write)
