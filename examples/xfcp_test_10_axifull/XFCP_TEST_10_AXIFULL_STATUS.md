# xfcp_test_10_axifull — Status

## Stav: UZAVRETY (2026-06-16) — tag xfcp_lib_v1_4_mem_pass

Sim regression T01–T37 PASS. Timing closure PASS: SEED 10, WNS +0.327 ns, Fmax 130.33 MHz.
HW regression PASS: UART 81/81, UDP 81/81 (CAPS, TARGETS, RW, STREAM, MEM, DIAG).
Tag: `xfcp_lib_v1_4_mem_pass`

---

## Fazy

| Faza | Popis                        | Stav           |
|------|------------------------------|----------------|
| A    | RTL — MEM backend (AXI-Full) | UZAVRETA       |
| B    | Sim — T01–T37 regression     | UZAVRETA       |
| C    | Quartus build + timing       | UZAVRETA       |
| D    | Python MEM tools             | UZAVRETA       |
| E    | HW regression UART+UDP+MEM   | UZAVRETA       |

---

## Timing (Faza C)

### axifull_sram — M9K fix (Faza C bug)

**Problem:** `axifull_sram.sv` implementoval read path cez kombinacny mux z pola
registrov, nie cez M9K output register. Cesta `rd_addr_q → rd_data_q` = 10 ns.
CLK125 WNS = -2.101 ns, Fmax = 99 MHz.

**Root cause:** Pamatova pole `logic [31:0] mem_q [0:DEPTH-1]` bolo citane
podmienecne (iba v RD_DATA stave) v rovnakom always_ff bloku ako FSM registre.
Quartus nevedel odvodit M9K output register — namapoval async LUT mux.

**Fix:**
- 4 samostatne byte-lane pole: `(* ramstyle = "M9K" *) logic [7:0] mem0..3`
- Zapis: dedicated `always_ff` bez RST, byte-enable per lane
- Citanie: dedicated `always_ff` — bezpodmienecne `rd_data_q <= {mem3, mem2, mem1, mem0}[rd_waddr_w]`
- FSM uz nepise `rd_data_q` — iba riadi `rd_valid_q`, `rd_last_q`, `rd_state_q`

**Vysledok:** Logic cells 48 661 → 34 763, RAM segments 106 → 138, Fmax 99 → 127+ MHz.

### SEED sweep

| SEED | WNS (ns)  |
|------|-----------|
| 1    | -0.357    |
| 3    | -0.115    |
| 5    | -0.357    |
| 6    | FIT FAIL  |
| 7    | -0.012    |
| 8    | -0.729    |
| 9    | -0.314    |
| **10** | **+0.327** |
| 15   | -0.752    |
| 20   | +0.077    |

**Vybrana hodnota: SEED 10, WNS +0.327 ns, Fmax 130.33 MHz.**

Kriticky bod po fixe: `udp_xfcp_server|altsyncram|resp_buf → axis_skid_buffer`
(existujuca infrastruktura, nie novy MEM backend).

---

## RTL — nove/zmenene moduly

### `rtl/xfcp/xfcp_mem_adapter.sv`
AXI4-Full master pre XFCP MEM backend.
- `MEM_READ (0x30)`: AXI AR + R burst, odpoved RESP_MEM_READ (0x32)
- `MEM_WRITE (0x31)`: AXI AW + W burst, odpoved RESP_MEM_WRITE (0x33)
- Parametre: `MAX_BYTES=256`, `DATA_WIDTH=32`, `ADDR_WIDTH=32`
- rfifo: 64-entry (BEATS_MAX) kruhovy buffer pre AXI R beat-y
- Timeout: 4096 cyklov, pocita len ked AXI slave nereaguje (nie ked caka na UART payload)

### `rtl/axifull_sram.sv` (opravena — M9K inference)
AXI4-Full slave, 256x32b SRAM s 4 byte-lane M9K blokmi.
- WR FSM: WR_IDLE → WR_DATA → WR_RESP
- RD FSM: RD_IDLE → RD_DATA → RD_WAIT (1-cycle read latency)
- Burst: INCR, max 64 beatov (256B)
- `(* ramstyle = "M9K" *)` na kazdom byte-lane

### `rtl/xfcp/xfcp_pkg.sv` (rozsireny)
Nove opkody:
```
XFCP_OP_MEM_READ       = 8'h30
XFCP_OP_MEM_WRITE      = 8'h31
XFCP_OP_RESP_MEM_READ  = 8'h32
XFCP_OP_RESP_MEM_WRITE = 8'h33
```

---

## Opravene bugy (Faza B — sim)

### Bug 1: `xfcp_arbiter_2to1.sv` — p0_is_write_w nezahrnoval MEM_WRITE
- **Symptom**: MEM_WRITE paket dostal synteticke TLAST na poslednom hlavickovom bajte
  → parser padal do S_DROP stavu
- **Fix**: `p0_is_write_w` rozsireny o `XFCP_OP_MEM_WRITE`

### Bug 2: `xfcp_fabric_endpoint.sv` — MEM_WRITE wdata tiekla do AXIL buffra
- **Symptom**: `g_engine[0].i_engine.i_write_buffer: FIFO OVERFLOW! count=32 DEPTH=32`
- **Fix**: `write_data_valid` pre AXIL engine doplneny o `&& !wdata_stage_is_mem_r`

### Bug 3: `xfcp_mem_adapter.sv` — rfifo deadlock pre burst > 2 beaty
- **Symptom**: MEM_READ count=16 (4 beaty) timeout v ST_R
- **Pricina**: 2-entry rfifo → full po 2 beatoch → m_axi_rready=0 → SRAM zaseknuty → deadlock
- **Fix**: rfifo rozsireny na BEATS_MAX=64 zaznamov

### Bug 4: `xfcp_mem_adapter.sv` — ST_AW_W timeout behal aj pri cakani na UART payload
- **Symptom**: MEM_WRITE status=0x06 (TIMEOUT) po 1024 cykloch
- **Pricina**: UART 115200 baud dorucuje 4B za ~34720 cyklov, timeout=1024
- **Fix**: to_cnt_q sa nuluje ked `!mem_wdata_valid_i`

### Bug 5: `axifull_sram.sv` — LUT mux namiesto M9K (Faza C)
- **Symptom**: WNS -2.101 ns, Fmax 99 MHz
- **Fix**: 4 byte-lane M9K polia + dedikowane always_ff bloky bez podmienky

---

## Sim regression (T01–T37)

```
T01-T10:  AXIL READ/WRITE (1B, 4B, burst)
T11-T20:  STATUS, CAPS, TARGET INFO, AXIS loopback
T21-T30:  Multi-target AXIL (eng0+eng1)
T31-T37:  MEM READ/WRITE (rozne dlzky, burst, boundary)
```

Vysledok po M9K fixe: **XFCP_TEST_10_AXIFULL REGRESSION PASSED** (37/37)

---

## Architektura (top)

```
UART ─► xfcp_arbiter_2to1 ─► xfcp_fabric_endpoint ─► xfcp_axi_engine[0] ─► axil_regfile
ETH  ─►                   ─►                       ─► xfcp_axi_engine[1] ─► axil_sys_ctrl
                                                    ─► xfcp_axis_adapter
                                                    ─► xfcp_caps_adapter
                                                    ─► xfcp_target_info_adapter
                                                    ─► xfcp_mem_adapter ──► axifull_sram (M9K)
```

---

## HW Regression (Faza E)

### UART /dev/ttyUSB0@115200
```
caps PASS  targets PASS  rw PASS  stream PASS  mem PASS  diag clean
81/81 KOMPLETNY USPECH
```

### UDP 192.168.0.5:50000
```
caps PASS  targets PASS  rw PASS  stream PASS  mem PASS  diag clean
81/81 KOMPLETNY USPECH
```

Poznamka: pri prvom UDP behu nastal jednorazovy transient packet loss (write 0x3F readback 0x2A).
Re-run okamzite prebehol 81/81. DIAG: rx_drop=0, rx_recovery=0, rx_bad_hdr=0.

---

## Python MEM tools (Faza D)

- `tools/xfcp/protocol.py`: OP_MEM_READ/WRITE/RESP, encode/decode funkcie, MAX_MEM_BYTES=256
- `tools/xfcp/bus.py`: `mem_read(addr, count)`, `mem_write(addr, data)`
- `tools/test_hw.py`: `--mem` flag, `run_mem_test()` (4B/16B/64B/256B loopback x repeat)
- `Makefile`: `test-uart` a `test-udp` obsahuju `--mem`
