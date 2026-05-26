# ETH Test — stav projektu

> Stav k: 2026-05-26
> Board: QMTech EP4CE55F23C8
> PHY: Realtek RTL8211 (GMII, 10/100/1000 Mbps)
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
