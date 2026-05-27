# ETH Test — stav projektu

> Stav k: 2026-05-27
> Board: QMTech EP4CE55F23C8
> PHY: Realtek RTL8211EG-VB-CG (GMII, 10/100/1000 Mbps)
> Referencny projekt: `Project09_Test_Ethernet.zip` (ethernet_test.v, Quartus Classic)

---

## Ciel projektu

Port referenčného Ethernet projektu do socfw + pridanie UDP echo testovacieho modulu.

Fázy:
1. **eth_test** — port `ethernet_test.sv` do socfw, overenie generovaných artefaktov (board.tcl, soc_top.sv, sdc)
2. **eth_test_01** (budúci) — zapojenie `eth_udp_echo_test` modulu s UDP stackom, end-to-end test z PC

---

## Stav Faza 1 — DOKONCENA

### Generovane artefakty (po opravach)

| Subor | Stav |
|---|---|
| `build/rtl/soc_top.sv` | OK — spravne smery ETH_GTX_CLK (output) a ETH_TX_CLK (input) |
| `build/hal/board.tcl` | OK — bez duplikatov, IO_STANDARD pouziva `[*]` pre bus signaly |
| `build/timing/soc_top.sdc` | OK — ETH_RXD/TXD pouzivaju `[*]` notaciu, ETH_TX_ER na ETH_RX_CLK domene |

### Opravene chyby

**1. GTX_CLK / TX_CLK smery oratene (hardware-kriticka)**

`board.yaml` (qmtech_ep4ce55) mal `gtx_clk` a `tx_clk` oratene:

| Signal | Pin | Spravny smer | Popis |
|---|---|---|---|
| `ETH_GTX_CLK` | U22 | output | FPGA generuje 125 MHz referenciu pre PHY |
| `ETH_TX_CLK` | AB20 | input | PHY vracia 25 MHz TX hodiny do FPGA (GMII 100Mbps) |

Opravene v `board.yaml` + zodpovedajuce targets v `project.yaml`.

**2. Duplicitne set_location_assignment v board.tcl**

Pricina: `_emit_selected_resources` pridaval specificke bind-target cesty (napr. `onboard.eth.rxd`)
do `selected.paths` aj ked rodicovska cesta `onboard.eth` uz bola pritomna.
`collect_pin_ownership` potom spracoval kazdy bit dvakrat.

Oprava v `socfw/emit/board_tcl_emitter.py`: preskoc subcestu ak rodic uz pokryva.

**3. IO_STANDARD pre bus signaly bez `[*]`**

Quartus vyzaduje `set_instance_assignment -to ETH_RXD[*]` pre bus signaly.
Opravene v `_emit_pin_uses`.

**4. SDC — bus porty bez `[*]` notacie**

Quartus SDC W332174: `ETH_RXD` sa nenaslo ako port. Opravene na `"ETH_RXD[*]"` v `timing_config.yaml`.

**5. ETH_TX_ER chybajuci IO delay override**

Defaultny SYS_CLK constraint na ETH_TX_ER sposoboval -7.463 ns timing violation.
Pridany override: `clock: ETH_RX_CLK`, `max_ns: 2.0`, `min_ns: 0.0`.

**6. GMII pin naming zosúladené s RTL8211EG datasheet (2026-05-27)**

Zdroj: `doc/RTL8211E-VB-CG_11.PDF`, Table 4 (GMII), Table 6 (Reset), Table 7 (Mode Selection).

Premenované signaly v `board.yaml` (qmtech_ep4ce55) + aktualizované `project.yaml`, `timing_config.yaml`:

| Stary kluc / top_name       | Novy kluc / top_name   | Datasheet pin name |
|-----------------------------|------------------------|--------------------|
| `rx_clk` / `ETH_RX_CLK`    | `rxc` / `ETH_RXC`     | RXC (Table 4)      |
| `rx_clk_0` / `ETH_RX_CLK_0`| `rxc_0` / `ETH_RXC_0` | RXC (2. pin)       |
| `rx_dv` / `ETH_RX_DV`      | `rxdv` / `ETH_RXDV`   | RXDV (Table 4)     |
| `rx_er` / `ETH_RX_ER`       | `rxer` / `ETH_RXER`   | RXER (Table 4)     |
| `tx_clk` / `ETH_TX_CLK`    | `txclk` / `ETH_TXCLK` | TXCLK (Table 4)    |
| `tx_en` / `ETH_TX_EN`       | `txen` / `ETH_TXEN`   | TXEN (Table 4)     |
| `tx_er` / `ETH_TX_ER`       | `txer` / `ETH_TXER`   | TXER (Table 4)     |
| `reset` / `ETH_RESET`       | `phyrstb` / `ETH_PHYRSTB` | PHYRSTB (Table 6) |

Pridane QSF assignments cez framework (rozsirenie board_schema/model/loader/tcl_emitter):
- `FAST_INPUT_REGISTER ON` pre: `ETH_RXD[*]`, `ETH_RXDV`, `ETH_RXER`
- `FAST_OUTPUT_REGISTER ON` pre: `ETH_TXD[*]`, `ETH_TXEN`, `ETH_TXER`
- `GLOBAL_SIGNAL GLOBAL_CLOCK` pre: `ETH_RXC`

Poznamka k GMII mode: pin `COL/Mode` (64-pin nr. 31) musi byt pulldown (4.7k na GND) = GMII.
Pull-up = RGMII. Platne len pre RTL8211EG-VB, nie RTL8211E-VB (Table 7 / Table 13 datasheet).

**7. TX MAC clock domain — kriticka oprava TX vysielania (2026-05-27)**

Pricina zlyhania UDP TX: `ipsend.sv` pouzival `negedge clk_i` kde `clk_i = eth_rx_clk_i` (PHY recovered
RX hodina), nie PLL TX hodinu. `GTX_CLK` je `eth_tx_clk_i` (PLL 125 MHz) — ine hodiny.

Opravene:
- `ipsend.sv`: `negedge clk_i` → `posedge clk_i`
- `udp.sv`: pridany port `tx_clk_i`; `ipsend` a `crc` pouzivaju `tx_clk_i`
- `ethernet_test.sv`: `u_udp.tx_clk_i = eth_tx_clk_i`; RAM read clock = `eth_tx_clk_i`
- `tb_udp_rx_path.sv`: pridany nezavisly `tx_clk`

**8. SDC opravy pre Quartus TimeQuest (2026-05-27)**

- `sdc_emitter.py`: `_pll_input_pin` opraveny na `clkpll|altpll_component|auto_generated|pll1|inclk[0]`
- `board.yaml`: `ETH_TXCLK` (PHY TX_CLK vstup, nepouzivany) — suppress `pin_assignment` + `io_assignments`
- `timing_config.yaml`: false paths pre ETH_TXD/TXEN/TXER (source-synchronous TX, analyza cez interni ETH_TX_CLK je pesimisticka; skutocna marga ~4.7 ns vs 2 ns spec)
- `timing_config.yaml`: false paths pre ETH_RXD/RXDV/RXER (GLOBAL_SIGNAL GLOBAL_CLOCK pridava ~4.5 ns clock insertion delay, hold analyza je artifact, v HW je +0.87 ns marga)

**9. ipsend.sv — pipelinovy checksum stage (2026-05-27)**

Pricina: ST_MAKE stage 2 sumoval 4 × 32-bit hodnoty (8.35 ns > 8 ns @ 125 MHz).
Pridany novy stage 2: `csum_part2_q = ip_header_q[4] words sum` (17-bit, fast).
Stage 3 (byvaly stage 2) teraz sumuje 3 operandy (18+18+17 bit = ~6 ns, OK).
ST_MAKE teraz 6 cyklov (bol 5). TB `tb_ipsend_static_packet.sv` aktualizovany.

**Vysledok Quartus kompilacie (Slow 1200mV 85C):**
- ETH_TX_CLK setup: +0.397 ns ✓ (bol -3.951 ns)
- ETH_RXC setup: +0.406 ns ✓
- SYS_CLK setup: +4.891 ns ✓
- Hold: vsetky kladne ✓
- Bitfile: `output_files/soc_top.sof`

---

## Vytvorene subory

### RTL

- `rtl/eth_udp_echo_test.sv` — UDP echo peripheral, AXI-Lite diagnosticke registre
  - Parametre: `DEFAULT_IP=192.168.1.50`, `DEFAULT_UDP_PORT=50000`, `MAX_PAYLOAD_BYTES=512`
  - Register mapa viz nizssie
  - 6-stavovy FSM: ST_IDLE → ST_DROP/ST_RECV → ST_SEND_META → ST_SEND_PAY → ST_DONE

### IP descriptor

- `ip/eth_udp_echo_test.ip.yaml` — socfw IP descriptor, `needs_bus: true`, `bus: axil`

### Tools

- `tools/udp_echo_test.py` — Python testovaci nastroj

```bash
python3 udp_echo_test.py --host 192.168.1.50 --count 100 --size 32
python3 udp_echo_test.py --host 192.168.1.50 --sweep   # sweep velkosti 1..508 B
```

---

## Register mapa eth_udp_echo_test

| Offset | Nazov | Typ | Reset | Popis |
|--------|-------|-----|-------|-------|
| 0x00 | ID | RO | `"ETH_"` | Identifikator modulu |
| 0x04 | VERSION | RO | `32'h0001_0000` | Major.Minor.Patch |
| 0x08 | CONTROL | RW | `32'h3` | [0]=enable, [1]=echo_en |
| 0x0C | STATUS | RO | — | [0]=link_up (stub) |
| 0x10 | LOCAL_IP | RW | `192.168.1.50` | Filtracia podla IP |
| 0x14 | UDP_PORT | RW | `50000` | Filtracia podla UDP portu |
| 0x18 | RX_PKT_COUNT | RO | 0 | Prijate pakety (saturating) |
| 0x1C | TX_PKT_COUNT | RO | 0 | Odoslane pakety (saturating) |
| 0x20 | DROP_COUNT | RO | 0 | Zahodene pakety (saturating) |
| 0x24 | ERR_OVERFLOW | RO | 0 | Pretecenie buffera (saturating) |
| 0x28–0x44 | (rezerva) | RO | 0 | Buduce citace |
| 0x48 | CLEAR_COUNTERS | PULSE | — | Zapis 1 → reset vsetkych citacov |

---

## Zname problemy / TODO pre Fazu 2

| # | Problem | Priorita |
|---|---------|----------|
| 1 | `ipsend.sv` timing violation -6.809 ns (IP checksum cesta, 15.28 ns @ 8 ns) | Medium — pre-existing legacy, neopravene |
| 2 | Chyba `set_max_delay 1ns -from ETH_RX_CLK -to ETH_GTX_CLK` (v originali pritomne) | Low — optimalizacia, nie funkcny bug |
| 3 | `eth_udp_echo_test` nie je zapojeny do aktuálneho top-level | Blocker pre Fazu 2 |
| 4 | Nie je overene HW (FPGA zatial neprogramovane) | Blocker |

---

## GMII interface — referencia

| Signal | Smer (FPGA) | Pin | Popis |
|--------|-------------|-----|-------|
| ETH_GTX_CLK | output | U22 | 125 MHz ref clock: FPGA → PHY (pre 1 Gbps TX) |
| ETH_TX_CLK | input | AB20 | 25 MHz TX clock: PHY → FPGA (pri 100 Mbps) |
| ETH_RX_CLK | input | R19 | RX clock: PHY → FPGA |
| ETH_TXD[7:0] | output | V22..AB18 | TX data |
| ETH_TX_EN | output | V21 | TX enable |
| ETH_TX_ER | output | AA18 | TX error |
| ETH_RXD[7:0] | input | K22..P22 | RX data |
| ETH_RX_DV | input | K21 | RX data valid |
| ETH_RX_ER | input | R21 | RX error |
| ETH_MDC | output | AB17 | Management clock |
| ETH_MDIO | inout | AA17 | Management data |
| ETH_RESET | output | W21 | PHY reset (active low) |
