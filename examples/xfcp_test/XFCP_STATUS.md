# XFCP projekt — aktuálny stav

> Stav k: 2026-05-18
> Board: QMTech EP4CE55F23C8 @ 50 MHz
> Protokol: XFCP cez UART 115200 baud (SOP=0xFE)
> HW testy: **PASS** — DynamicScanner naskenoval 6 slotov, LED/SEG7 ovladane cez Python

---

## Ciel projektu

Obojsmerna komunikacia medzi PC (Python app) a FPGA cez seriovú linku (UART).
Na FPGA strane su periferie pripojene cez AXI-Lite zbernicu:
- **LED** (6-bit, onboard)
- **LED** (8-bit, PMOD J10)
- **LED** (8-bit, PMOD J11)
- **7-segmentovy displej** (3 digity, onboard)
- **UART diagnostika** (status, baud, error clear)
- **SysCtrl** (uptime, reset, fault detection)

---

## Architektura systemu

```
PC (Python tools/main.py)
  |  /dev/ttyUSB0  115200 baud
  |  XFCP protokol: SOP=0xFE, [opcode][count 2B BE][addr 4B BE][data MSB-first]
  v
axis_uart_rx (AXIS_TLAST=0)
  |  AXI-Stream 8-bit, TLAST=0 (parser pouziva COUNT, nie TLAST)
  v
xfcp_axil_bridge  (xfcp_rx_parser -> xfcp_axi_engine -> xfcp_tx_packetizer)
  |  AXI-Lite 32-bit master
  v
AXI-Lite 1-to-6 decoder  (slot = addr[18:16], stride=0x10000)
  |
  +-- Slot 0 @ 0xFF000000 : axil_sys_ctrl          (ID="SYSC")
  +-- Slot 1 @ 0xFF010000 : axil_uart_adapter       (ID="UART")
  +-- Slot 2 @ 0xFF020000 : axil_regs / onboard LED (ID="OUT_")  6-bit
  +-- Slot 3 @ 0xFF030000 : axil_regs / PMOD J10    (ID="OUT_")  8-bit
  +-- Slot 4 @ 0xFF040000 : axil_regs / PMOD J11    (ID="OUT_")  8-bit
  +-- Slot 5 @ 0xFF050000 : axil_seven_seg_adapter  (ID="SEG7")
```

### Datovy tok

```
Request : [FE][opcode][count_hi][count_lo][addr 4B][data_words MSB-first]
Response: [FE][opcode][DEV_TYPE 2B][DEV_STR 16B][payload_words MSB-first][00]
           ^--- 20B header ---^                ^--- data ---^   ^terminator^
```

---

## RTL — stav modulov

### Implementovane moduly

| Modul | Subor | Popis |
|---|---|---|
| `xfcp_pkg` | xfcp/xfcp_pkg.sv | XFCP protokol typy, opkody, SOP konstanty |
| `xfcp_rx_parser` | xfcp/xfcp_rx_parser.sv | Parser poziadaviek (FSM, dual FIFO) — port logic[55:0] |
| `xfcp_tx_packetizer` | xfcp/xfcp_tx_packetizer.sv | Serializacia odpovedi, 20B header + payload |
| `xfcp_axi_engine` | xfcp/xfcp_axi_engine.sv | XFCP -> AXI-Lite, multi-word, watchdog |
| `xfcp_axil_bridge` | xfcp/xfcp_axil_bridge.sv | Top bridge (parser+engine+packetizer) |
| `xfcp_fifo` | xfcp/xfcp_fifo.sv | Fall-through FIFO |
| `xfcp_fabric_endpoint` | xfcp/xfcp_fabric_endpoint.sv | Multi-slave dispatcher (mimo scope) |
| `xfcp_id_rom` | xfcp/xfcp_id_rom.sv | ROM streamer pre device ID |
| `axi_pkg` | axi/axi_pkg.sv | AXI typy, structs |
| `axi_interfaces` | axi/axi_interfaces.sv | axi4lite_if, axi4s_if interfejsy |
| `uart_pkg` | uart/uart_pkg.sv | UART typy, config |
| `uart_baud_gen` | uart/uart_baud_gen.sv | Baud rate generator |
| `uart_core_rx` | uart/uart_core_rx.sv | UART RX Moore FSM |
| `uart_core_tx` | uart/uart_core_tx.sv | UART TX Mealy FSM |
| `uart` | uart/uart.sv | UART top-level |
| `axis_uart_rx` | axis/axis_uart_rx.sv | UART RX -> AXI-Stream (AXIS_TLAST=0) |
| `axis_uart_tx` | axis/axis_uart_tx.sv | AXI-Stream -> UART TX |
| `axil_regfile` | axil/axil_regfile.sv | Genericka registrova banka |
| `axil_regs` | axil/axil_regs.sv | LED register (ID="OUT_") |
| `axil_sys_ctrl` | axil/axil_sys_ctrl.sv | SysCtrl (ID="SYSC") |
| `axil_uart_adapter` | axil/axil_uart_adapter.sv | UART config AXI adapter (ID="UART") |
| `axil_seven_seg_adapter` | axil/axil_seven_seg_adapter.sv | 7-seg adapter (ID="SEG7") |
| `seven_seg_mux` | segment/seven_seg_mux.sv | Multiplexovany 7-seg driver |
| `seven_seg_mux_packed` | segment/seven_seg_mux_packed.sv | Packed variant |
| `xfcp_uart_mmio_top` | xfcp_uart_mmio_top.sv | TOP integracny modul (6 slotov) |

### Zrusene/nahradene moduly

| Modul | Poznamka |
|---|---|
| `xfcp_axil_bridge_2.sv` | Zruseny — nahradeny cistejsim `xfcp_axil_bridge.sv` |
| `axil_xfcp_mod.sv` | Stary protokol (SOP=0xFF) — pouzivan pre referenciu, mimo buildu |

---

## Quartus — stav kompilacia

| Krok | Stav | Poznamka |
|---|---|---|
| `make syn` (quartus_map) | **PASS** | 0 errors, 2555 LEs |
| `make fit` (quartus_fit) | **PASS** | 0 errors, 9 warnings (LVTTL 3.3V piny) |
| `make asm` (assembler) | **PASS** | 0 errors |
| `make sta` (timing) | **PASS** | slack 9.2 ns, komfortna rezerva pre 50 MHz |
| `make program` | **PASS** | FPGA flashnuta, HW overene |

### Vyuzitie zdrojov (po fit, EP4CE55F23C8)

| Zdroj | Pouzite | Dostupne | % |
|---|---|---|---|
| Logic elements | 2 210 | 55 856 | 4 % |
| Registers | 1 475 | 55 856 | 3 % |
| Pins | 37 | 325 | 11 % |
| Memory bits | 2 560 | 2 396 160 | <1 % |
| PLLs | 0 | 4 | 0 % |

---

## Registrova mapa

Adresny priestor: `0xFF000000` + `slot * 0x10000`

### Slot 0 — axil_sys_ctrl (ID: `SYSC`)

| Offset | Pravo | Nazov | Popis |
|--------|-------|-------|-------|
| 0x00 | RO | COMPONENT_ID | ASCII "SYSC" = 0x53595343 |
| 0x04 | RO | HW_STATUS | [0]=pll_locked, [3]=ic_timeout |
| 0x08 | RW | CONTROL | [0]=sw_reset, [2]=clear_faults (PULSE) |
| 0x0C | RO | UPTIME | Sekundy od resetu |
| 0x10 | RO | FAULT_ADDR | Posledna adresa s AXI timeout |
| 0x14 | RO | FAULT_STATUS | Bitmapa chybovych slotov |

### Slot 1 — axil_uart_adapter (ID: `UART`)

| Offset | Pravo | Nazov | Popis |
|--------|-------|-------|-------|
| 0x00 | RO | COMPONENT_ID | ASCII "UART" = 0x55415254 |
| 0x04 | RO | STATUS | busy, overrun, frame, parity flags |
| 0x08 | RW | BAUD_DIV | Prescaler (default 434 = 50 MHz/115200) |
| 0x0C | WO | ERRCLR | Zapis 1 vymaze error flags |

### Slot 2 — axil_regs / onboard LED (ID: `OUT_`)

| Offset | Pravo | Nazov | Popis |
|--------|-------|-------|-------|
| 0x00 | RO | COMPONENT_ID | ASCII "OUT_" = 0x4F55545F |
| 0x04 | RW | LED_STATE | [5:0] = led_00_o (onboard 6-bit LED) |

### Slot 3 — axil_regs / PMOD J10 (ID: `OUT_`)

| Offset | Pravo | Nazov | Popis |
|--------|-------|-------|-------|
| 0x00 | RO | COMPONENT_ID | ASCII "OUT_" = 0x4F55545F |
| 0x04 | RW | LED_STATE | [7:0] = led_01_o (J10 8-bit LED) |

### Slot 4 — axil_regs / PMOD J11 (ID: `OUT_`)

| Offset | Pravo | Nazov | Popis |
|--------|-------|-------|-------|
| 0x00 | RO | COMPONENT_ID | ASCII "OUT_" = 0x4F55545F |
| 0x04 | RW | LED_STATE | [7:0] = led_02_o (J11 8-bit LED) |

### Slot 5 — axil_seven_seg_adapter (ID: `SEG7`)

| Offset | Pravo | Nazov | Popis |
|--------|-------|-------|-------|
| 0x00 | RO | COMPONENT_ID | ASCII "SEG7" = 0x53454737 |
| 0x04 | RW | DIGITS | packed: [4:0]=dig0, [9:5]=dig1, [14:10]=dig2 |

Format digitu (5 bitov): `[4]`=decimal point, `[3:0]`=hex 0-F

---

## Hardware — piny a konektory

| Periferny signal | Quartus signal | FPGA pin | Poznamka |
|---|---|---|---|
| UART RX | UART_RX | J2 | Onboard USB-UART bridge |
| UART TX | UART_TX | J1 | Onboard USB-UART bridge |
| Onboard LED[5:0] | ONB_LEDS | A6,B7,A7,B8,A8,E4 | 6-bit |
| SEG segments[7:0] | ONB_SEG | A4,B1,B4,A5,C3,A3,B2,C4 | 7-seg + bodka |
| SEG digits[2:0] | ONB_DIG | B6,B3,B5 | 3 cifry (common anode) |
| J10 LED[7:0] | J10 piny 1-4,7-10 | H1,F1,E1,C1,H2,F2,D2,C2 | PMOD LED 8-bit |
| J11 LED[7:0] | J11 piny 1-4,7-10 | R1,P1,N1,M1,R2,P2,N2,M2 | PMOD LED 8-bit |

---

## Python tools — stav

| Subor | Stav | Popis |
|-------|------|-------|
| `tools/bus/xfcp.py` | OK | XFCPBus — opraveny protokol (SOP=0xFE, big-endian, 20B resp header) |
| `tools/core/scanner.py` | OK | DynamicScanner — opravene duplikatne ID (OUT_, OUT_1, OUT_2) |
| `tools/core/peripheral.py` | OK | BasePeripheral abstrakcia |
| `tools/core/register.py` | OK | AxilRegister deskriptor (RMW, bitfields) |
| `tools/modules/sys_ctrl.py` | OK | SysCtrl (SYSC) mapovanie |
| `tools/modules/gpio.py` | OK | GPIOIn, GPIOOut, SevenSeg — aktualizovane |
| `tools/modules/uart_diag.py` | OVERIT | UARTDiag — treba overit register mapu voci axil_uart_adapter |
| `tools/modules/sdram_ctrl.py` | MIMO SCOPE | SDRAMController — projekt nema SDRAM |
| `tools/main.py` | OK | Hlavne menu, monitor, diagnostika |

### Znamy problem — uart_diag.py

Registrova mapa v `uart_diag.py` nebola overena voci aktualnemu `axil_uart_adapter.sv`.
Pred prvym HW testom je nutne porovnat offsety.

---

## Simulacie — stav

### Otestovane (AXI-Lite periferie)

| Testbench | Testy | Vysledok |
|---|---|---|
| tb_axil_regfile | 10 | PASS |
| tb_axil_sys_ctrl | 9 | PASS |
| tb_axil_seven_seg_adapter | 6 | PASS |
| tb_axil_uart_adapter | 15 | PASS |
| tb_axil_regs | 11 | PASS |

### Otestovane (XFCP stack)

| Testbench | Testy | Vysledok | Popis |
|---|---|---|---|
| tb_xfcp_rx_parser | 7 | PASS | READ/WRITE header, error cases, back-to-back, backpressure |
| tb_xfcp_axil_bridge | 5 | PASS | WRITE+READ integracny test bez UART |

### Chybajuce simulacie

| Testbench | Priorita | Poznamka |
|---|---|---|
| tb_xfcp_tx_packetizer | MEDIUM | overit 20B header + MSB-first payload standalone |
| tb_xfcp_axi_engine | MEDIUM | WRITE/READ + timeout standalone |
| tb_uart_core_tx | LOW | |

---

## Stav projektu — UZAVRETY (2026-05-18)

Vsetky ciele splnene:
- RTL implementovany a prelozeny (syn + fit + asm + sta, 0 errors)
- Regression 9/9 PASS (sim/Makefile regression)
- HW bring-up PASS — DynamicScanner naskenoval vsetkych 6 slotov
- Python tools funkcne (main.py: monitor, diagnostika, LED/SEG7 ovladanie)

### Opravene bugy (session 2026-05-18)

| Bug | Modul | Symptom | Oprava |
|-----|-------|---------|--------|
| Fix A | xfcp_axi_engine.sv | Mrtvy pipeline kod v ST_RD_WAIT: ARVALID=1 nastavene kombinacne, ale ST_NEXT videl ARVALID=0 (reset defaults) → vzdy ST_RD_ADDR | Odstranenie pipeline kodu, cisto sekvencius READ: ST_RD_ADDR→ST_RD_WAIT→ST_NEXT |
| Fix B | xfcp_axi_engine.sv | RREADY=1'b1 vzdy; rfifo w_ready nenapojene → pri plnom rfifo stratene RDATA | rfifo_w_ready_w napojene na FIFO, m_axil.RREADY=rfifo_w_ready_w |
| Fix D | xfcp_rx_parser.sv | WRITE s COUNT=0 presiel COUNT alignment check (0%4==0), pushol header, engine caka na wfifo ktory nikdy nepride → deadlock | go_drop += WRITE&&dec_words==0 |

### Simulacie (vsetky PASS)

```
make -C sim regression   →   9/9 PASS
```

| Testbench | Testy | Vysledok |
|---|---|---|
| tb_axil_regfile | 10 | PASS |
| tb_axil_sys_ctrl | 9 | PASS |
| tb_axil_seven_seg_adapter | 6 | PASS |
| tb_axil_uart_adapter | 15 | PASS |
| tb_axil_regs | 11 | PASS |
| tb_uart_core_rx | 12 | PASS |
| tb_xfcp_rx_parser | 7 | PASS |
| tb_xfcp_axil_bridge | 5 | PASS |
| tb_xfcp_uart_mmio_top | 4 | PASS |

---

## Historicky prehled zmien

| Datum | Commit | Co sa zmenilo |
|---|---|---|
| 2026-05-16 | c7aa616 | Inicialna verzia projektu |
| 2026-05-17 | 4b6b8a8 | RTL top implementovany, Quartus flow PASS, Python tools opravene, Makefile rozsireny |
| 2026-05-17 | 7f14861 | +2 PMOD LED sloty (J10/J11), opraveny decoder (addr[18:16], 3h4/3h5), scanner duplikat fix |
| 2026-05-18 | HEAD | Bug fixes A+B+D (engine pipeline, RREADY, parser count=0); sim regression 9/9; HW PASS |
