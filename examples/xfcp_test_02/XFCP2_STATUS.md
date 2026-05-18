# XFCP Test 02 — stav projektu

> Stav k: 2026-05-18 (faza 1+2 dokoncene)
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
| tb_xfcp_tx_packetizer | 2/6 | STUB-PASS | T1-T2 PASS; T3-T6 TODO |
| tb_xfcp_axi_engine | 3/9 | STUB-PASS | T1-T3 PASS; T4-T9 TODO |

### Integracne testy

| Testbench | Testy | Stav | Poznamka |
|---|---|---|---|
| tb_xfcp_axil_bridge | 5 | PASS | baseline, copy z xfcp_test, overene |
| tb_xfcp_fabric_endpoint | 3/8 | STUB-PASS | T1-T3 PASS; T4-T8 TODO |
| tb_xfcp_uart_mmio_top | 4 | PASS | aktualizovane pre fabric_endpoint, LITTLE_ENDIAN=0 |

**Regression: make regression → XFCP_TEST_02 REGRESSION PASSED (2026-05-18)**

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

---

## Poradie dalsich krokov

### ~~Faza 1 — overit zdedene testy~~ DONE

### ~~Faza 2 — opravit stub TB bugy~~ DONE (regression PASS)

### Faza 3 — dokoncit stub testy + RTL opravy z navrhy_03.md

Stub testy (TODO):
1. `tb_xfcp_axi_engine`: T4 multi-word, T6 backpressure, T9 timeout
2. `tb_xfcp_tx_packetizer`: T3 backpressure, T4 back-to-back, T5 late resp_done
3. `tb_xfcp_fabric_endpoint`: T4 invalid addr, T5-T6 back-to-back, T7-T8 multi-word

RTL opravy:

| # | Modul | Problem | Popis |
|---|---|---|---|
| E | xfcp_rx_parser.sv | Neuplna TLAST validacia | Posledny payload byte bez TLAST musi ist do go_drop |
| G | xfcp_axi_engine.sv | Timeout neposle error response | timeout → ST_DONE bez resp_done → order_fifo deadlock |

### ~~Faza 4 — integracny top test~~ DONE

`tb_xfcp_uart_mmio_top.sv` aktualizovany a overeny (4/4 PASS).
LITTLE_ENDIAN=0 nastaveny explicitne v `xfcp_uart_mmio_top.sv`.

### ~~Faza 5a — socfw YAML deskriptory~~ DONE

`project.yaml`, `timing_config.yaml`, `ip/xfcp_uart_mmio.ip.yaml` vytvorene.
IP descriptor: `xfcp_fabric_endpoint.sv` nahradzuje `xfcp_axil_bridge.sv` vo synthesis zozname.

### Faza 5b — Quartus build + HW test

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
