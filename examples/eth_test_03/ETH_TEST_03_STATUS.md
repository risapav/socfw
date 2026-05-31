# ETH_TEST_03 — Status

**Dátum:** 2026-05-31
**Stav:** HW TESTOVANIE — Faza 4A: eth_header_parser prepísaný (bez packed struct), MAC_DEBUG build pripravený

---

## Cieľ projektu

Kompletný Ethernet UDP echo stack na QMTech EP4CE55 + RTL8211EG PHY (GMII 1Gbps).

```
RX: gmii_rx_mac -> eth_header_parser -> ipv4_header_parser -> udp_header_parser
                -> udp_rx_meta_assembler -> udp_echo_app
TX: udp_echo_app -> udp_ipv4_tx_builder -> async_fifo (CDC) -> TX controller -> gmii_tx_mac
```

---

## Quartus Build Status

- **Syntéza:** 0 errors, 8 warnings (ASYNC_REG atribút ignorovaný — benígne)
- **Fitter + Assembler + STA:** 0 errors
- **SOF:** `output_files/soc_top.sof` (posledný build — pred Faza 4A zmenami)

### Timing Summary (posledný Quartus build, pred Faza 4A)

| Clock | Slow 85°C Fmax | Slow 85°C Slack | Fast 0°C Slack | Stav |
|---|---|---|---|---|
| ETH_RXC (125 MHz) | 120.74 MHz | **−0.290 ns** | +0.424 ns | Slow FAIL, Fast PASS |
| ETH_TX_CLK (125 MHz) | 132.64 MHz | +0.461 ns | +0.829 ns | OK |
| SYS_CLK (50 MHz) | 67.8 MHz | +5.251 ns | +6.047 ns | OK |

**Pred fixom:** ETH_RXC slack = −7.18 ns (Fmax 65.86 MHz)
**Po fixe udp_ipv4_tx_builder:** ETH_RXC slack = −0.290 ns — routing-limitované FF→RAM cesty
**Faza 4A:** meta FIFO registered stage pridaný → očakáva sa zlepšenie ETH_RXC (čaká na rebuild)

---

## Výsledky testov — 13/13 ALL PASS (po Faza 4A zmenách)

```bash
# Z examples/eth_test_03/sim/
make regression
```

| Testbench | Typ | Výsledok |
|---|---|---|
| tb_crc32_eth | Questa | 3/3 PASS |
| tb_gmii_tx_mac | Questa | 8/8 PASS |
| tb_gmii_rx_mac | Questa | 5/5 PASS |
| tb_mac_stream_tx_rx_stream | Questa | 10/10 PASS |
| tb_eth_header_builder | Questa | 3/3 PASS |
| tb_eth_header_parser | Questa | 12/12 PASS |
| tb_ipv4_checksum | Questa | 4/4 PASS |
| tb_ipv4_header_parser | Questa | 15/15 PASS |
| tb_udp_header_parser | Questa | 21/21 PASS |
| tb_udp_ipv4_tx_builder | Questa | 3/3 PASS |
| tb_rx_path | Verilator | 5/5 PASS |
| tb_echo_path | Verilator | 5/5 PASS |
| tb_echo_path_dual_clock | Verilator | 5/5 PASS (CDC 8.000/8.013 ns) |

---

## HW Test — Chronológia (2026-05-30)

### Konfigurácia

```
PC: 192.168.20.234/24 na enp0s20f0u4u1 (USB Ethernet, 1000Mb/s)
FPGA: LOCAL_IP=192.168.20.50, LOCAL_MAC=00:0a:35:01:fe:c0, UDP_PORT=8080
Link: 1000Mb/s (overené ethtool)
Static ARP: ip neigh replace 192.168.20.50 lladdr 00:0a:35:01:fe:c0 nud permanent
```

### LED mapa (po oprave LED_ACTIVE_LOW=1)

**LAYER_DEBUG=1 (Debug Build B):**
- LED0 = heartbeat (~1Hz)
- LED1 = PHY reset done
- LED2 = RXDV activity
- LED3 = `frame_done` (gmii_rx_mac, L1)
- LED4 = `eth_hdr_valid` (eth_header_parser, L2)
- LED5 = `ipv4_hdr_valid` (ipv4_header_parser, L3)

**LAYER_DEBUG=0 (Normal mode):**
- LED0 = heartbeat
- LED1 = PHY reset done
- LED2 = RXDV activity
- LED3 = `udp_accept` (rx_meta_valid)
- LED4 = `tx_mac_busy`
- LED5 = `tx_en` (GMII TXEN)

---

### Test 1 — Prvý HW test (normálna build, LAYER_DEBUG=0)

**Kód:** EXPECT_PREAMBLE=1, LED_ACTIVE_LOW=0 (BUG), promiscuous=0

**Výsledok:**
- LED3 svieti stále → `udp_accept=0` → FPGA nikdy neprijal UDP
- Žiadna odpoveď v tcpdump

**Záver:** Nič nedosiahlo UDP vrstvu. Príčina neznáma.

---

### Test 2 — Build A (EXPECT_PREAMBLE=0)

**Kód:** EXPECT_PREAMBLE=0 (raw data, preamble sa nespracúva)

**Výsledok:**
- LED3 stále nesvieti (po oprave LED polarity) → stále žiadny UDP accept
- Žiadna odpoveď

**Záver:** EXPECT_PREAMBLE nie je koreňová príčina. PHY posiela štandard preamble + SFD.

---

### Test 3 — Debug Build B (LAYER_DEBUG=1, EXPECT_PREAMBLE=1)

**Opravy pred testom:**
- `LED_ACTIVE_LOW` = 0 → **1** (board je active-low, chyba v kóde)
- `ALLOW_NO_PREAMBLE` dead parameter odstránený z `gmii_rx_mac`
- LAYER_DEBUG=1 implementovaný v `eth_debug_leds` (LED3/4/5 = L1/L2/L3 pipeline)
- Pripojenné signály: `frame_done_o`, `hdr_valid_o` na eth+ipv4 parseroch

**Výsledok:**
```
LED1: svieti (PHY reset done ✓)
LED2: bliká  (RXDV activity ✓)
LED3: blikla (frame_done ✓) ← gmii_rx_mac správne dokončuje rámce
LED4: neblikla (eth_hdr_valid ✗) ← eth_header_parser DROPUJE VŠETKY rámce
LED5: neblikla (ipv4_hdr_valid ✗) ← nedosiahlo L3
```

**Záver:** `gmii_rx_mac` funguje (EXPECT_PREAMBLE=1 správne deteguje preamble+SFD).
`eth_header_parser` zahadzuje každý rámec. Príčina: `drop_decision_w` vyhodnocuje TRUE.

---

### Test 4 — Promiscuous L2 (eth_header_parser.promiscuous_i=1)

**Kód:** eth_header_parser.promiscuous_i=1'b1, LAYER_DEBUG=1

**Overenie tcpdump pred testom:**
```
PC → FPGA: e0:4f:43:5b:59:3c > 00:0a:35:01:fe:c0, IPv4, UDP dport=8080
Hex: 000a 3501 fec0 e04f 435b 593c 0800 ...
     ^^^^^^^^^^                           dst_mac = 00:0a:35:01:fe:c0 = LOCAL_MAC ✓
```
PC posiela na správnu MAC adresu!

**Výsledok:**
```
LED4: blikla ✓ ← s promiscuous=1 eth_header_parser PRIJÍMA rámce
```

**Záver potvrdený:** `drop_decision_w` v HW vyhodnocuje `header_reg.dst_mac != local_mac_i` ako TRUE
napriek tomu, že PC odosiela bytes 00:0a:35:01:fe:c0 = LOCAL_MAC.
Toto je záhada — v simulácii 12/12 PASS, v HW comparison failuje.

---

### Test 5 — Promiscuous L2+L3

**Kód:** eth_header_parser.promiscuous_i=1'b1, LAYER_DEBUG=1

**Výsledok:**
```
LED5: blikla ✓ ← ipv4_header_parser PRIJÍMA rámce
```

**Záver:** L3 prechádza (dst_ip=192.168.20.50 matching funguje, alebo ipv4_header_parser nemá strict filter).

---

### Test 6 — Full promiscuous (aktuálna kódová verzia) — ČAKÁ NA SPUSTENIE

**Kód (aktuálne nastavenia v kóde):**
- `eth_header_parser.promiscuous_i = 1'b1`
- `udp_header_parser.promiscuous_i = 1'b1`
- `LAYER_DEBUG = 0` (vidieť TX LEDs: LED3=udp_accept, LED4=tx_busy, LED5=tx_en)
- `LED_ACTIVE_LOW = 1` (správne)

**Čaká na:** `make build && make compile && make program` + test

**Očakávania:**
- Ak LED3 neblikne → udp_header_parser alebo meta assembler failuje (alebo oba parsers L2/L3 nefungujú ani s promiscuous)
- Ak LED3 blikne ale LED4/5 nie → TX FSM alebo builder failuje
- Ak LED4/5 bliknú → GMII TX aktívny → problém je na PHY alebo frame formát

---

### Test 7 — MAC_DEBUG build (Faza 4A — PRIPRAVENÝ, čaká na HW)

**Kód (aktuálne nastavenia):**
- `eth_header_parser.promiscuous_i = 1'b0` (strict — testuje opravu)
- `udp_header_parser.promiscuous_i = 1'b1` (promiscuous — neblokuje TX diagnostiku)
- `MAC_DEBUG = 1` (LED3=hdr_done, LED4=mac_accept, LED5=mac_drop)
- `LED_ACTIVE_LOW = 1` (správne)

**LED mapa (MAC_DEBUG=1):**
- LED0 = heartbeat (~1Hz)
- LED1 = PHY reset done
- LED2 = RXDV activity
- LED3 = hdr_done_pulse (blikne pri každom spracovanom byte 13)
- LED4 = hdr_accept_pulse (blikne keď MAC filter PRIJME frame) ← CIEĽ
- LED5 = hdr_drop_pulse (blikne keď MAC filter ZAHODÍ frame)

**Očakávaný výsledok po oprave:**
- LED3 bliká ✓ (parser dosahuje byte 13)
- LED4 bliká ✓ (MAC filter prijíma — `mac_accept_q=1` pri `dst_mac=00:0a:35:01:fe:c0`)
- LED5 nie ✓ (žiadne dropovania)

**Ak LED4 stále nebliká:** `mac_accept_q` je stále 0 → problém je inde (RXD pin mapping, data corruption)

---

## Faza 4A — Implementované zmeny (2026-05-31)

### eth_header_parser.sv — kompletný prepis (navrhy_16)
- Odstránený `eth_hdr_t header_reg` (packed struct) — synthesis bug v Quartus Lite
- Explicitné registre: `dst_mac_q`, `src_mac_q`, `ethertype_q`, `mac_accept_q`
- `mac_accept_q` registrovaný pri byte 5 z kombinačného `dst_mac_complete_w = {dst_mac_q[47:8], s_axis_tdata}`
- State transition pri byte 13 používa IBA `mac_accept_q` (nie kombinačný packed struct compare)
- Nové výstupné porty: `hdr_done_pulse_o`, `hdr_accept_pulse_o`, `hdr_drop_pulse_o` (1-cycle pulzy)
- Debug capture: `dbg_dst_mac_o`, `dbg_mac_accept_o` (prvý frame po resete)

### eth_debug_leds.sv — MAC_DEBUG mode (navrhy_16+17)
- Nový parameter `MAC_DEBUG = 1'b0`
- Nové vstupy: `mac_hdr_done_i`, `mac_accept_i`, `mac_drop_i`
- Toggle sync + stretch counter pre každý signál (eth_rx_clk → sys_clk)
- Priorita: MAC_DEBUG > LAYER_DEBUG > normal

### ethernet_test_03_top.sv
- `eth_header_parser.promiscuous_i = 1'b0` (revert — testuje opravený parser)
- Zapojené nové pulz výstupy parsera na LED debug modul
- Meta FIFO timing fix: registered stage pred zápisom (navrhy_16 sekcia 9)
- `MAC_DEBUG = 1'b1` v `eth_debug_leds`

### Simulácie — 13/13 ALL PASS (po zmenách)

---

## Otvorené záhady

### Záhada 1: MAC Comparison Bug v eth_header_parser

**Symptóm:** `drop_decision_w` = TRUE v HW napriek tomu, že:
- PC odoslal dst_mac = 00:0a:35:01:fe:c0 (overené tcpdump)
- LOCAL_MAC = 48'h000A3501FEC0 = 00:0a:35:01:fe:c0 (správne)
- gmii_rx_mac správne deteguje preamble/SFD (bajty nie sú bit-reversed)
- Simulácia: eth_header_parser 12/12 PASS

**OPRAVENÉ v Faza 4A** — eth_header_parser prepísaný bez packed struct comparison.
`mac_accept_q` je teraz registrovaný pri byte 5 z kombinačného `dst_mac_complete_w`.
**Čaká na HW overenie (Test 7 — MAC_DEBUG build).**

### Záhada 2: TX Silence

**Symptóm:** Žiadna FPGA odpoveď v tcpdump ani s promiscuous=1 na L2+L3.
L3 prechádza (LED5 blikla), L4+ neznáme.

**Čaká na výsledky Test 6** (LED3/4/5 v LAYER_DEBUG=0 mode).

---

## Stav RTL modulov

| Modul | Súbor | Stav |
|---|---|---|
| `crc32_eth` | `mac/crc32_eth.sv` | PASS — 3/3 |
| `gmii_tx_mac` | `mac/gmii_tx_mac.sv` | PASS — 8/8 |
| `gmii_rx_mac` | `mac/gmii_rx_mac.sv` | PASS — 5/5; FCS nie je stripovaný |
| `eth_header_builder` | `l2/eth_header_builder.sv` | PASS — 3/3 |
| `eth_header_parser` | `l2/eth_header_parser.sv` | PASS sim 12/12; HW MAC comparison bug |
| `ipv4_checksum` | `l3/ipv4_checksum.sv` | PASS — 4/4 |
| `ipv4_header_parser` | `l3/ipv4_header_parser.sv` | PASS — 15/15 |
| `udp_header_parser` | `l4/udp_header_parser.sv` | PASS — 21/21 |
| `udp_rx_meta_assembler` | `l4/udp_rx_meta_assembler.sv` | PASS (cez echo_path) |
| `udp_echo_app` | `l4/udp_echo_app.sv` | PASS (cez echo_path) |
| `udp_ipv4_tx_builder` | `l4/udp_ipv4_tx_builder.sv` | PASS — timing fix: ST_PREP + partial_csum_q |
| `async_fifo` | `cdc/async_fifo.sv` | PASS — FWFT + no_rw_check |
| `cdc_two_flop_synchronizer` | `cdc/cdc_two_flop_synchronizer.sv` | OK |
| `eth_debug_leds` | `util/eth_debug_leds.sv` | PASS — LAYER_DEBUG implementovaný |
| `ethernet_test_03_top` | `ethernet_test_03_top.sv` | HW testovanie |

---

## Kľúčové RTL rozhodnutia

### hdr_pre_valid_o a _pre porty
`udp_header_parser` vystavuje `hdr_pre_valid_o` (fires pri `byte_cnt==7`).
`udp_rx_meta_assembler` triggeruje priamo — eliminuje 1-cycle edge-detection delay.
`udp_echo_app` má `s_axis_tready=1` aj v ST_IDLE pri `rx_meta_valid_i=1` — prvý payload bajt
zachytený počas handshake.

### udp_ipv4_tx_builder — timing fix (navrhy_13)
Pôvodný problém: 28-case header mux + checksum v jednom cykle → −7.18 ns.
Fix: ST_IDLE latchne metadata + partial_csum_q (9 slov bez total_len).
     ST_PREP dokončí checksum (1 add + 2 folds) z registrovaných vstupov + naplní hdr_q[0:27].
     ST_HDR vysiela hdr_q[hdr_cnt_q] priamo (registrované pole).
Výsledok: −7.18 ns → −0.290 ns (Fmax 66 → ~121 MHz).

### Dual-clock CDC architektúra
```
RX domain (eth_rx_clk):  gmii_rx_mac -> parsery -> udp_echo_app -> udp_ipv4_tx_builder
                          -> async_fifo.wr_side  (pkt_fifo 9b/2048, meta_fifo 96b/4)
TX domain (eth_tx_clk):  async_fifo.rd_side -> TX FSM -> gmii_tx_mac
```

### UDP checksum
TX: 0x0000 (disabled). RX: DROP_NONZERO_CHECKSUM=0, flag `udp_checksum_unchecked_o`.

### LED_ACTIVE_LOW oprava
Board QMTech EP4CE55 má common-anode LEDs (active-LOW). Pôvodný kód mal LED_ACTIVE_LOW=0.
Opravené na LED_ACTIVE_LOW=1 v `ethernet_test_03_top.sv`.

---

## Known Issues / Zostatok

- [ ] **HW: MAC comparison bug** — eth_header_parser dropuje napriek správnemu dst_mac; koreňová príčina neznáma (navrhy_15)
- [ ] **HW: TX silence** — žiadna FPGA odpoveď; čaká na Test 6 (LAYER_DEBUG=0)
- [ ] **ETH_RXC slow corner −0.290 ns** — fast corner prechádza; možná súvislosť s MAC comparison bugom
- [ ] `gmii_rx_mac` STRIP_FCS — dlhodobý cieľ
