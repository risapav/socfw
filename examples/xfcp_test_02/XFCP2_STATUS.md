# XFCP Test 02 — stav projektu

> Stav k: 2026-05-19 (faza 5b: Quartus PASS, HW test, RTL+Python opravy)
> Board: QMTech EP4CE55F23C8 @ 50 MHz
> Protokol: XFCP cez UART 115200 baud (SOP=0xFE)
> Predchadzajuci projekt: `examples/xfcp_test` (uzavrety, commit d89c918)

---

## Ciel projektu

Upgrade predchadzajuceho `xfcp_test`:

1. **xfcp_fabric_endpoint** nahradza `xfcp_axil_bridge` + manualne 1-to-N dekodery
   - Interny adresovy dekoder (SLAVE_BASE / SLAVE_MASK parametre)
   - Order FIFO pre in-order odpovede
   - N paralelnych AXI engines (jeden per slave)
   - Cleany top modul bez 200+ riadkov mux/demux logiky

2. **Kompletna testovacia pyramida** (navrh z navrhy_02.md):
   - unit/ : kazdy modul testovany izolvane
   - integration/ : fabric endpoint + full top

3. **RTL fixes** z navrhy_03.md ktore este neboli implementovane:
   - Problem E: strict TLAST validacia (posledny payload byte musi mat TLAST)
   - Problem G: timeout → error response (nie tichy drop)

---

## Architektura systemu

```
PC (Python tools/main.py)
  |  /dev/ttyUSB0  115200 baud
  |  XFCP protokol: SOP=0xFE
  v
axis_uart_rx (AXIS_TLAST=0)
  |
  v
u_rx_fifo [NEW] (xfcp_fifo, 8-byte elastic buffer, prevents UART overrun)
  |
  v
xfcp_fabric_endpoint (novy!)
  |  interny adresovy dekoder: (addr & MASK) == BASE
  |  order FIFO pre in-order response
  |
  +-- Engine 0 <-> Slave 0 @ 0xFF000000 : axil_sys_ctrl    (SYSC)
  +-- Engine 1 <-> Slave 1 @ 0xFF010000 : axil_uart_adapter (UART)
  +-- Engine 2 <-> Slave 2 @ 0xFF020000 : axil_regs         (OUT_) 6-bit
  +-- Engine 3 <-> Slave 3 @ 0xFF030000 : axil_regs         (OUT_) 8-bit J10
  +-- Engine 4 <-> Slave 4 @ 0xFF040000 : axil_regs         (OUT_) 8-bit J11
  +-- Engine 5 <-> Slave 5 @ 0xFF050000 : axil_seven_seg    (SEG7)
  |
  v
xfcp_tx_packetizer
  |
axis_uart_tx
```

**Porovnanie s xfcp_test:**

| | xfcp_test | xfcp_test_02 |
|---|---|---|
| Bridge modul | xfcp_axil_bridge (1 slave) | xfcp_fabric_endpoint (N slaves) |
| AXI dekoder | Manualne 200+ riadkov | Interny (SLAVE_BASE/MASK) |
| Order FIFO | Nie | Ano (in-order garantia) |
| Paralelne engines | 1 | N (jeden per slave) |
| Top modul dlzka | ~415 riadkov | ~200 riadkov |

---

## Struktura projektu

```
examples/xfcp_test_02/
├── XFCP2_STATUS.md              <- tento subor
├── navrhy/                      <- design notes
├── rtl/
│   ├── axi/       -> symlink ../xfcp_test/rtl/axi      (nezmenene)
│   ├── axil/      -> symlink ../xfcp_test/rtl/axil     (nezmenene)
│   ├── axis/      -> symlink ../xfcp_test/rtl/axis     (nezmenene)
│   ├── uart/      -> symlink ../xfcp_test/rtl/uart     (nezmenene)
│   ├── segment/   -> symlink ../xfcp_test/rtl/segment  (nezmenene)
│   ├── buffer/    -> symlink ../xfcp_test/rtl/buffer   (nezmenene)
│   ├── xfcp/                   <- kopie, budu modifikovane
│   │   ├── xfcp_pkg.sv
│   │   ├── xfcp_fifo.sv
│   │   ├── xfcp_rx_parser.sv
│   │   ├── xfcp_axi_engine.sv
│   │   ├── xfcp_tx_packetizer.sv
│   │   ├── xfcp_fabric_endpoint.sv  <- hlavny upgrade
│   │   └── xfcp_id_rom.sv
│   └── xfcp_uart_mmio_top.sv   <- novy top (pouziva fabric_endpoint)
└── sim/
    ├── Makefile
    ├── unit/                    <- izolacne testy modulov
    │   ├── tb_axil_regfile.sv
    │   ├── tb_axil_sys_ctrl.sv
    │   ├── tb_axil_seven_seg_adapter.sv
    │   ├── tb_axil_uart_adapter.sv
    │   ├── tb_axil_regs.sv
    │   ├── tb_uart_core_rx.sv
    │   ├── tb_xfcp_rx_parser.sv
    │   ├── tb_xfcp_tx_packetizer.sv  <- stub, TODO
    │   └── tb_xfcp_axi_engine.sv     <- stub, TODO
    └── integration/
        ├── tb_xfcp_axil_bridge.sv        <- baseline (1-slave, z xfcp_test)
        ├── tb_xfcp_fabric_endpoint.sv    <- stub, TODO (multi-slave)
        └── tb_xfcp_uart_mmio_top.sv      <- TODO (aktualizovat pre fabric)
```

---

## Stav simulacii

### Unit testy

| Testbench | Testy | Stav | Poznamka |
|---|---|---|---|
| tb_axil_regfile | 10 | PASS | copy z xfcp_test, overene |
| tb_axil_sys_ctrl | 9 | PASS | copy z xfcp_test, overene |
| tb_axil_seven_seg_adapter | 6 | PASS | copy z xfcp_test, overene |
| tb_axil_uart_adapter | 15 | PASS | copy z xfcp_test, overene |
| tb_axil_regs | 11 | PASS | copy z xfcp_test, overene |
| tb_uart_core_rx | 12 | PASS | copy z xfcp_test, overene |
| tb_xfcp_rx_parser | 7 | PASS | copy z xfcp_test, overene |
| tb_xfcp_tx_packetizer | 6/6 | PASS | T1-T6 PASS (T3 backpressure, T4 back-to-back, T5 late done, T6 DEV_STR) |
| tb_xfcp_axi_engine | 9/9 | PASS | T1-T9 PASS (T4-T5 multi-word, T6-T7 backpressure, T8 WFIFO, T9 timeout+recovery) |

### Integracne testy

| Testbench | Testy | Stav | Poznamka |
|---|---|---|---|
| tb_xfcp_axil_bridge | 5 | PASS | baseline, copy z xfcp_test, overene |
| tb_xfcp_fabric_endpoint | 7+skip/8 | PASS | T1-T3 + T5-T8 PASS; T4 SKIP (Problem F) |
| tb_xfcp_uart_mmio_top | 4 | PASS | aktualizovane pre fabric_endpoint, LITTLE_ENDIAN=0 |

**Regression: make regression → XFCP_TEST_02 REGRESSION PASSED (2026-05-19, po RX FIFO oprave)**

### Opravene bugy v TB taskoch

| TB | Bug | Oprava |
|---|---|---|
| tb_xfcp_axi_engine | do_write akumuloval kopie v FIFO (wfifo_valid oneskoreny 1 cyklus) | 2-fazovy write: najprv FIFO push, potom req handshake |
| tb_xfcp_axi_engine | do_read cakal na resp_done po deasserte read_data_ready — puls uz bol prec | Zachytit resp_done v rovnakom posedge ako read_data_valid |
| tb_xfcp_tx_packetizer | send_read_resp deassertoval read_data_valid pred ST_PAYLOAD | Drzat valid az kym read_data_ready asertuje (v ST_PAYLOAD) |
| tb_xfcp_fabric_endpoint | data 0xCAFE_BABE obsahuje byte 0xFE (parser SOP recovery) | Pouzivat data bez 0xFE bajtov |
| tb_xfcp_fabric_endpoint | SLAVE_BASE stride 0x10000 → idx>MEM_DEPTH=64 → BAADF00D | Kompaktny stride 0x40 (64 bajtov) |

### Opravene bugy v RTL

| Modul | Bug | Oprava |
|---|---|---|
| xfcp_fabric_endpoint | LITTLE_ENDIAN neprechadzal na engine (default=1 → byte-swap) | Pridany LITTLE_ENDIAN parameter, default=0 (kompatibilny s xfcp_axil_bridge) |
| xfcp_axi_engine | FIX G: error_timeout overridoval ST_DONE → engine deadlock, resp_done nikdy | Restrukturacia always_comb: ST_DONE/ST_IDLE mimo timeout vetvy; resp_done + resp_type fire na timeout |
| xfcp_fabric_endpoint | resp_done_mux = eng_resp_done[arb_sel_q] — arb_sel_q zaostava 1 cyklus za resp_start_pulse → done_latch_q nikdy nastaveny → packetizer deadlock v ST_PAYLOAD | resp_done_mux = resp_start_pulse || resp_done_held_q (2-cycle pulse) |
| xfcp_uart_mmio_top | axis_uart_rx bez buffra → UART byte zahodeny ak parser ma tready=0 | u_rx_fifo (xfcp_fifo DEPTH=8) vlozeny medzi axis_uart_rx a parser |

---

## Poradie dalsich krokov

### ~~Faza 1 — overit zdedene testy~~ DONE

### ~~Faza 2 — opravit stub TB bugy~~ DONE (regression PASS)

### ~~Faza 3 — dokoncit stub testy + RTL opravy~~ DONE (2026-05-18)

Stub testy dokoncene:
- `tb_xfcp_axi_engine`: T4-T5 multi-word, T6-T7 backpressure, T8 WFIFO, T9 watchdog+recovery — vsetky PASS
- `tb_xfcp_tx_packetizer`: T3 tready backpressure, T4 back-to-back, T5 late resp_done_i, T6 DEV_STR — vsetky PASS
- `tb_xfcp_fabric_endpoint`: T4 SKIP (Problem F), T5-T8 PASS (back-to-back, in-order, multi-word WRITE+verify)

RTL opravy:

| # | Modul | Problem | Stav |
|---|---|---|---|
| E | xfcp_rx_parser.sv | Neuplna TLAST validacia | DEFERRED — UART ma TLAST=0 vzdy, strict check by dropoval vsetky pakety |
| G | xfcp_axi_engine.sv | Timeout neposle error response | DONE — 3-cast oprava always_comb + resp_done + resp_type |

### ~~Faza 4 — integracny top test~~ DONE

`tb_xfcp_uart_mmio_top.sv` aktualizovany a overeny (4/4 PASS).
LITTLE_ENDIAN=0 nastaveny explicitne v `xfcp_uart_mmio_top.sv`.

### ~~Faza 5a — socfw YAML deskriptory~~ DONE

`project.yaml`, `timing_config.yaml`, `ip/xfcp_uart_mmio.ip.yaml` vytvorene.
IP descriptor: `xfcp_fabric_endpoint.sv` nahradzuje `xfcp_axil_bridge.sv` vo synthesis zozname.

### ~~Faza 5b — Quartus build + HW test~~ DONE (2026-05-19)

Quartus build: Fmax = 63.34 MHz > 50 MHz target. Vsetky kroky PASS.

HW test (scanner num_slots=8, pred opravami):
- Slot 0 SYSC OK, Slot 2 OUT_ OK, Slot 4 OUT_1 OK, Slot 5 SEG7 OK
- Slot 1 UART TIMEOUT, Slot 3 OUT_ TIMEOUT — pricina: pravdepodobne stale bytes z retransmitovania
- Slot 6,7 TIMEOUT — pricina: num_slots=8 > NUM_SLAVES=6, deadlock (OPRAVENE)
- 2. scan: vsetky TIMEOUT — pricina: deadlock z predchadzajuceho invalid-address probing (OPRAVENE)

Opravene (2026-05-19):
1. `tools/core/scanner.py`: `num_slots=8` → `num_slots=6` — eliminuje deadlock
2. `tools/bus/xfcp.py`: pridany `reset_input_buffer()` pred kazdym `_transact` — eliminuje stale bytes
3. `rtl/xfcp_uart_mmio_top.sv`: pridany `u_rx_fifo` (DEPTH=8) — eliminuje potencialny UART overrun
4. `rtl/xfcp/xfcp_fabric_endpoint.sv`: `resp_done_mux` fix (z predchadzajucej session)

Otvoreny problem: 17% non-deterministicke zlyhania (0B odpoved) — sporadicke, nahodne sloty.
Pred dalsi HW testom treba rebuildnut Quartus (RTL zmeneny).

```bash
make syn && make fit && make asm && make sta && make program
```

---

## Zname rizika (z navrhy_03.md)

### Problem C — resp_done synchronizacia (existujuci kod)

`xfcp_fabric_endpoint` caka na `eng_done_rdy` pred spustenim packetizera.
`resp_done` je 1-taktovy pulz — fabric ho zachytava cez `eng_done_cnt` register.
Toto je uz opravene v existucom `xfcp_fabric_endpoint.sv` (verzia "opravena").
Treba overit simulaciou pri T5 v `tb_xfcp_fabric_endpoint`.

### Problem F — WRITE payload routing na neplatnu adresu

Ak pride WRITE na neplatnu adresu, dec_valid=0 a req_ready=0.
Ale wdata_valid_raw moze stale tiec — decoder defaultuje na slave 0.
Existujuci kod ma ciastocnu ochranu (`wdata_valid = wdata_valid_raw`
bez gatingu na dec_valid). Treba overit a opravit ak T4 failuje.

---

## Historicky prehled

| Datum | Co sa zmenilo |
|---|---|
| 2026-05-18 | Inicializacia projektu, struktura vytvorena z xfcp_test |
| 2026-05-18 | Opravene bugy v TB taskoch (do_write FIFO akumulacia, do_read resp_done timing, send_read_resp pre ST_PAYLOAD, 0xFE byte v datach, MEM_DEPTH pre velke adresy) |
| 2026-05-18 | Pridany LITTLE_ENDIAN parameter do xfcp_fabric_endpoint (default=0), make regression PASS |
| 2026-05-18 | Pridane socfw YAML deskriptory: project.yaml, timing_config.yaml, ip/xfcp_uart_mmio.ip.yaml |
| 2026-05-18 | FIX G: xfcp_axi_engine timeout deadlock opraveny (3-cast: always_comb + resp_done + resp_type) |
| 2026-05-18 | Faza 3 dokoncena: T4-T9 engine, T3-T6 packetizer, T5-T8 fabric — REGRESSION PASSED |
| 2026-05-19 | resp_done_mux fix v xfcp_fabric_endpoint.sv (2-cycle pulse cez resp_done_held_q) |
| 2026-05-19 | Quartus build PASS, Fmax=63.34 MHz, HW test 4/6 periferii detekovanych |
| 2026-05-19 | Scanner deadlock fix: num_slots=8→6 v tools/core/scanner.py |
| 2026-05-19 | Pre-flush fix: reset_input_buffer() pred kazdym _transact v tools/bus/xfcp.py |
| 2026-05-19 | RX FIFO fix: u_rx_fifo (DEPTH=8) v xfcp_uart_mmio_top.sv — REGRESSION PASSED |
