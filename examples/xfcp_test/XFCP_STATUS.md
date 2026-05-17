# XFCP projekt — aktuálny stav

> Stav k: 2026-05-16
> Board: QMTech EP4CE55F23C8 @ 50 MHz
> Protokol: XFCP cez UART 115200 baud
> HW testy: nezačaté

---

## Cieľ projektu

Obojsmerná komunikácia medzi PC (Python app) a FPGA cez sériovú linku (UART).
Na FPGA strane sú periférie pripojené cez AXI-Lite zbernicu:
- **LED** (6-bit, onboard, ladenie)
- **7-segmentový displej** (3 digity, onboard) — J11 a J10 konektor
- **UART diagnostika** (loopback / status)
- **SysCtrl** (uptime, reset, bus fault detection)

---

## Architektúra systému

```
PC (Python main.py)
  |  /dev/ttyUSB0  115200 baud
  |  XFCP protokol: [0xFF][opcode][addr 4B][len 2B][data]
  v
UART RX/TX (axis_uart_rx / axis_uart_tx)
  |  AXI-Stream 8-bit
  v
xfcp_axil_bridge  (xfcp_rx_parser → xfcp_axi_engine → xfcp_tx_packetizer)
  |  AXI-Lite 32-bit
  v
AXI-Lite Interconnect / Decoder
  |  Base: 0xFF000000, stride: 0x10000 (64 KB / slot), max 32 slotov
  |
  +-- Slot 0x00 @ 0xFF000000 : axil_sys_ctrl    (ID="SYSC")
  +-- Slot 0x01 @ 0xFF010000 : axil_uart_adapter (ID="UART")
  +-- Slot 0x02 @ 0xFF020000 : axil_regfile/LED  (ID="OUT_")
  +-- Slot 0x03 @ 0xFF030000 : axil_seven_seg    (ID="SEG7")
  (dalsi sloty rezervovane)
```

---

## RTL — stav modulov

### Hotove moduly (exist, implementovane)

| Modul | Subor | Popis |
|---|---|---|
| `xfcp_pkg` | xfcp/xfcp_pkg.sv | XFCP protokol typy, opkody, SOP konstanty |
| `xfcp_rx_parser` | xfcp/xfcp_rx_parser.sv | Parser XFCP poziadaviek (6-stavovy FSM, dual FIFO) |
| `xfcp_tx_packetizer` | xfcp/xfcp_tx_packetizer.sv | Serializacia odpovedi, dual-slot buffer, ID ROM |
| `xfcp_axi_engine` | xfcp/xfcp_axi_engine.sv | XFCP → AXI-Lite prevodnik, multi-word, watchdog |
| `xfcp_axil_bridge` | xfcp/xfcp_axil_bridge.sv | Top-level bridge (parser+engine+packetizer) |
| `xfcp_axil_bridge_2` | xfcp/xfcp_axil_bridge_2.sv | Alternativna verzia bridge |
| `xfcp_fabric_endpoint` | xfcp/xfcp_fabric_endpoint.sv | Multi-slave dispatcher (NUM_SLAVES=4, in-order) |
| `xfcp_fifo` | xfcp/xfcp_fifo.sv | Fall-through FIFO pre XFCP data/header |
| `xfcp_id_rom` | xfcp/xfcp_id_rom.sv | ROM streamer pre device ID (20 bytov) |
| `axil_xfcp_mod` | axil/axil_xfcp_mod.sv | Jednoduchý XFCP-to-AXI-Lite bridge (alternativa) |
| `axil_slave_model` | axil/axil_slave_model.sv | AXI-Lite slave model (na testovanie) |
| `axi_pkg` | axi/axi_pkg.sv | AXI typy, structs, enums |
| `axi_interfaces` | axi/axi_interfaces.sv | axi4lite_if, axi4_if, axi4s_if interfejsy |
| `axi_error_policy` | axi/axi_error_policy.sv | Error typy a AXI response mapovanie |
| `uart` | uart/uart.sv | Kompletny UART (RX+TX top-level) |
| `uart_core_rx` | uart/uart_core_rx.sv | UART RX Moore FSM, parity, frame error |
| `uart_core_tx` | uart/uart_core_tx.sv | UART TX Mealy FSM, LSB-first |
| `uart_baud_gen` | uart/uart_baud_gen.sv | Baud rate generator (start/half/end tick) |
| `uart_pkg` | uart/uart_pkg.sv | UART typy, config register, FSM stavy |
| `axis_uart_rx` | axis/axis_uart_rx.sv | UART RX wrapper s AXI-Stream master |
| `axis_uart_tx` | axis/axis_uart_tx.sv | UART TX wrapper s AXI-Stream slave |
| `axis_fifo_sync` | axis/axis_fifo_sync.sv | Sync AXI-Stream FIFO (FWFT, konfig. hlbka) |
| `skid_buffer` | buffer/skid_buffer.sv | Full-throughput pipeline register |
| `seven_seg_mux` | segment/seven_seg_mux.sv | Multiplexovany 7-segment driver (COMMON_ANODE) |
| `seven_seg_mux_packed` | segment/seven_seg_mux_packed.sv | Wrapper s packed digit vstupom |

### CHYBAJUCE moduly (treba implementovat — PRIORITA 1)

Tieto subory referencuje `ip/xfcp_uart_mmio.ip.yaml` ale neexistuju:

| Modul | Subor (ocakavany) | Popis |
|---|---|---|
| `xfcp_uart_mmio_top` | rtl/xfcp_uart_mmio_top.sv | **TOP-LEVEL** — integracny modul |
| `axil_sys_ctrl` | rtl/axil_sys_ctrl.sv | SysCtrl peripheral (uptime, sw_reset, fault) |
| `axil_uart_adapter` | rtl/axil_uart_adapter.sv | UART AXI-Lite adapter (status, baud, data) |
| `axil_regfile` | rtl/axil_regfile.sv | Genericka registrova banka (RO/RW/W1C/PULSE) |
| `axil_regs` | rtl/axil_regs.sv | Konkretne instancie registrov (LED, ...) |
| `axil_seven_seg_adapter` | rtl/axil_seven_seg_adapter.sv | 7-seg AXI-Lite adapter (ID="SEG7") |

---

## Registrova mapa (planovana)

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
| 0x04 | RO | STATUS | uart_status_t bity (busy, err flags) |
| 0x08 | RW | BAUD_DIV | Prescaler (default 434 = 50MHz/115200) |
| 0x0C | WO | ERRCLR | Zapis 1 vymaze error flags |

### Slot 2 — LED register (ID: `OUT_`)

| Offset | Pravo | Nazov | Popis |
|--------|-------|-------|-------|
| 0x00 | RO | COMPONENT_ID | ASCII "OUT_" = 0x4F55545F |
| 0x04 | RW | LED_STATE | [5:0] = led_o (onboard 6-bit LED) |

### Slot 3 — axil_seven_seg_adapter (ID: `SEG7`)

| Offset | Pravo | Nazov | Popis |
|--------|-------|-------|-------|
| 0x00 | RO | COMPONENT_ID | ASCII "SEG7" = 0x53454737 |
| 0x04 | RW | DIGITS | packed: [4:0]=dig0, [9:5]=dig1, [14:10]=dig2 |

Format digitu (5 bitov): `[4]`=decimal point, `[3:0]`=hex hodnota 0-F

---

## Hardware — piny a konektory

### Onboard piny (QMTech EP4CE55F23C8)

| Periféria | Signal | Piny | Poznamka |
|-----------|--------|------|---------|
| UART RX | UART_RX | J2 | Onboard USB bridge |
| UART TX | UART_TX | J1 | Onboard USB bridge |
| LED [5:0] | ONB_LEDS | A6,B7,A7,B8,A8,E4 | 6-bit onboard LED |
| SEG segments | ONB_SEG[7:0] | A4,B1,B4,A5,C3,A3,B2,C4 | 7-seg segmenty |
| SEG digits | ONB_DIG[2:0] | B6,B3,B5 | 3 cifry |

### Konektory J10 / J11 (PMOD)

7-segmentovy displej a LED jsou fyzicky pripojene cez J10/J11:

| Konektor | Piny FPGA |
|----------|-----------|
| J10 pin 1-4,7-10 | H1,F1,E1,C1,H2,F2,D2,C2 |
| J11 pin 1-4,7-10 | R1,P1,N1,M1,R2,P2,N2,M2 |

---

## Python tools — stav

| Subor | Stav | Popis |
|-------|------|-------|
| `tools/bus/xfcp.py` | OK | XFCPBus driver (read32/write32/read_block) |
| `tools/core/scanner.py` | OK | DynamicScanner (auto-detekcia slotov) |
| `tools/core/peripheral.py` | OK | BasePeripheral abstrakcia |
| `tools/core/register.py` | OK | AxilRegister deskriptor (RMW, bitfields) |
| `tools/modules/sys_ctrl.py` | OK | SysCtrl (SYSC) mapovanie |
| `tools/modules/gpio.py` | OK | GPIOIn, GPIOOut, SevenSeg |
| `tools/modules/uart_diag.py` | ? | UARTDiag — treba overit registrovu mapu |
| `tools/modules/sdram_ctrl.py` | ? | SDRAMController — pravdepodobne mimo scope |
| `tools/main.py` | Rozostavaný | Hlavne menu, monitor, diagnostika; debug kód v scan() |

**Zname problemy v Python tools:**
- `scanner.py`: duplicitny `scan()` blok — stary kód zakomentovany stringom `"""..."""` (nie riadkovymi komentarmi), druhý `for slot` cyklus skenuje rozsah(32) ale preskakuje blacklist
- `main.py`: debug blok (`id_sdram = bus.read32(0xFF0E0000)`) nechany bez podmienky
- `SevenSeg.run_test()`: zakomentovany kod v string-quotes, logika nekonzistentna

---

## Simulacie — stav (2026-05-16)

`sim/` adresar vytvoreny. Vsetky AXI-Lite peripherals otestovane:

| Testbench | Testy | Vysledok |
|---|---|---|
| tb_axil_regfile | 10 | PASS |
| tb_axil_sys_ctrl | 9 | PASS |
| tb_axil_seven_seg_adapter | 6 | PASS |
| tb_axil_uart_adapter | 15 | PASS |
| tb_axil_regs | 11 | PASS |

---

## Co zostava — poradie priorit

```
PRIORITA 1 [RTL] xfcp_uart_mmio_top.sv — TOP integracny modul
   Instancie: xfcp_axil_bridge, axil_sys_ctrl, axil_uart_adapter,
              axil_regs (LED), axil_seven_seg_adapter
   AXI-Lite decoder: 4 sloty @ 0xFF000000+N*0x10000
   Pinout: UART RX/TX, LED[5:0], SEG[7:0], DIG[2:0]

PRIORITA 2 [RTL] Syntetizovat a flashnut do FPGA (Quartus 25.1 Lite)

PRIORITA 3 [HW] Spustit Python main.py — overit XFCP komunikaciu
   T1: DynamicScanner deteguje SYSC, SEG7, OUT_, UART
   T2: Zapis do LED registra -> fyzicka LED sa rozsvieti
   T3: Zapis do SEG7 -> displej zobrazuje hodnotu
   T4: SysCtrl uptime rastie, pll_locked=1

PRIORITA 4 [Python] Vycistit tools/:
   Opravit scanner.py duplicitny scan()
   Vycistit main.py debug blok
   Overit UARTDiag register mapu voci axil_uart_adapter
```
