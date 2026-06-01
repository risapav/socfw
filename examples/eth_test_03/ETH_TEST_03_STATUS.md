# ETH_TEST_03 — Status

**Dátum:** 2026-06-01
**Stav:** HW TESTOVANIE — Faza 4G: GMII TX output register fix (root cause TX silence)

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
- **SOF:** `output_files/soc_top.sof` (build Faza 4G, Mon Jun 1 18:10 2026)

### Timing Summary (Faza 4G build, Mon Jun 1 18:10 2026)

| Clock | Slack Setup Slow 85°C | Slack Hold | Stav |
|---|---|---|---|
| ETH_RXC (125 MHz) | **+0.444 ns** | +0.428 ns | PASS |
| ETH_TX_CLK (125 MHz) | +0.793 ns | +0.448 ns | PASS |
| SYS_CLK (50 MHz) | +5.341 ns | +0.449 ns | PASS |

**Timing história:**
- Pred fixom: ETH_RXC slack = −7.18 ns (Fmax 65.86 MHz)
- Faza 4A (4-CSUM-state): +0.448 ns PASS
- Faza 4E (RX_PIPE_DEBUG na J11): +0.291 ns PASS
- Faza 4F (TX_PATH_DEBUG na J11): +0.444 ns PASS
- Faza 4G (GMII TX output reg): +0.793 ns PASS (ETH_TX_CLK)

---

## Výsledky testov — 16/16 ALL PASS

```bash
# Z examples/eth_test_03/sim/
make regression
```

| Testbench | Typ | Výsledok |
|---|---|---|
| tb_crc32_eth | Questa | 3/3 PASS |
| tb_gmii_tx_mac | Questa | 8/8 PASS |
| tb_gmii_rx_mac | Questa | 5/5 PASS |
| tb_gmii_rx_mac_sfd_boundary | Questa | PASS |
| tb_gmii_rx_eth_align | Questa | PASS |
| tb_mac_stream_tx_rx_stream | Questa | 10/10 PASS |
| tb_eth_header_builder | Questa | 3/3 PASS |
| tb_eth_header_parser | Questa | 12/12 PASS |
| tb_ipv4_checksum | Questa | 4/4 PASS |
| tb_ipv4_header_parser | Questa | 15/15 PASS |
| tb_udp_header_parser | Questa | 21/21 PASS |
| tb_udp_ipv4_tx_builder | Questa | 3/3 PASS |
| tb_rx_path | Verilator | 5/5 PASS |
| tb_echo_path | Verilator | 5/5 PASS |
| tb_echo_path_dual_clock | Verilator | 5/5 PASS (CDC dual-clock) |

---

## HW Test — Chronológia (2026-05-31)

### Konfigurácia

```
PC: 192.168.20.234/24 na enp0s20f0u4u1 (USB Ethernet, 1000Mb/s)
FPGA: LOCAL_IP=192.168.20.50, LOCAL_MAC=00:0a:35:01:fe:c0, UDP_PORT=8080
Static ARP: ip neigh replace 192.168.20.50 lladdr 00:0a:35:01:fe:c0 nud permanent
```

### LED mapa (MAC_DEBUG=1, aktuálny build)

- LED0 = heartbeat (~1Hz)
- LED1 = PHY reset done (steady)
- LED2 = RXDV activity (bliká pri príjme)
- LED3 = `hdr_done_pulse` (1-cycle stretch: spracovaný hlavičkový rámec)
- LED4 = `hdr_accept_pulse` (1-cycle stretch: MAC filter PRIJAL)
- LED5 = `hdr_drop_pulse` (1-cycle stretch: MAC filter ZAHODIL)

---

### Test 1 (prvý HW test, normálna build)

**Kód:** EXPECT_PREAMBLE=1, LED_ACTIVE_LOW=0 (BUG), promiscuous=0

**Výsledok:** LED3 svieti stále, žiadna odpoveď.
**Záver:** LED_ACTIVE_LOW bug + RXDV debug chýbajúci.

---

### Test 2 — Build A (EXPECT_PREAMBLE=0)

**Výsledok:** LED3 nesvieti, žiadna odpoveď.
**Záver:** EXPECT_PREAMBLE=0 nie je riešenie; PHY posiela štandard preamble.

---

### Test 3 — Debug Build B (LAYER_DEBUG=1)

**Opravy:** LED_ACTIVE_LOW=1, LAYER_DEBUG implementovaný.

**Výsledok:**
```
LED2: bliká  (RXDV ✓)
LED3: blikla (frame_done ✓) — gmii_rx_mac správne dekóduje rámce
LED4: neblikla (eth_hdr_valid ✗) — eth_header_parser dropuje
LED5: neblikla
```
**Záver:** parser dostáva bajty, ale MAC comparison failuje.

---

### Test 4 — Promiscuous L2

**Kód:** promiscuous_i=1'b1 na eth_header_parser.

**Výsledok:** LED4 blikla ✓.
**Záver:** S promiscuous=1 parser prijíma. Problém je v MAC comparison.

---

### Test 5 — Promiscuous L2+L3

**Výsledok:** LED5 blikla ✓ (ipv4_header_parser prechádza).

---

### Test 6 — MAC_DEBUG (Faza 4A: eth_header_parser prepísaný bez packed struct)

**Kód:** promiscuous_i=1'b0, MAC_DEBUG=1, eth_header_parser prepísaný.

**Výsledok (2026-05-31):**
```
LED2: bliká  (RXDV ✓)
LED3: bliká  (hdr_done_pulse ✓) — parser dosahuje byte 13
LED4: NEbliká (hdr_accept_pulse ✗) — MAC comparison stále FAIL
LED5: bliká  (hdr_drop_pulse ✓) — všetky rámce sú zahadzované
```

**Záver:** Prepis z packed struct na explicitné registre NEVYRIEŠIL HW problém.
MAC comparison failuje aj s novým kódom. Príčina zostáva neznáma.

**Hypotézy:**
- SFD (0xD5) uniká do stream ako prvý byte — parser odoberá dst_mac[47:40]=0xD5
- RXD pinové mapovanie je iné ako expected
- LOCAL_MAC parameter parameter nesedí s reálnou adresou
- Iný problém v bit/byte orderi

---

### Test 7 — Preamble suppression fix + MAC_DEBUG (2026-05-31)

**Oprava:** gmii_rx_mac.sv — RX_IDLE deteguje 0xD5 priamo a prechádza do RX_SFD.
Predtým: RX_IDLE akceptoval iba 0x55. RTL8211EG PHY posiela RXDV od SFD (0xD5), nie od preamble → RX_IDLE zostal v RX_IDLE.

**Výsledok:**
```
LED3: bliká  ✓ — OPRAVA FUNGUJE, MAC prijíma bajty
LED4: NEbliká ✗ — MAC comparison stále FAIL
LED5: bliká  ✓
```

**Záver:** Preamble suppression bug opravený. MAC comparison je stále problém.

---

### Test 8 — Faza 4B: promiscuous L2+L3+L4 + txb_fire_w fix

**Kód:** eth/ipv4/udp promiscuous=1, LAYER_DEBUG=0 (rx_meta_valid/tx_mac_busy/eth_txen).
**Výsledok:** LED3/4/5 neblikajú. rx_meta_valid NIKDY nevzniká. TX ticho.
**Záver:** Problém je pred rx_meta_valid. Konkrétna vrstva neznáma.

---

### Test 9 — Faza 4C: LAYER_DEBUG=1 (frame_done/eth_hdr/ipv4_hdr)

**Kód:** LAYER_DEBUG=1, L2/L3/L4 promiscuous=1.
**Výsledok:** LED3/4/5 preblikli ✓. ipv4_hdr_valid potvrdený. Ale 0/6 echo FAIL.
**Záver:** RX cesta funguje po L3 (ipv4_hdr_valid). Kde sa stráca pred rx_meta_valid — neznáme.

---

### Test 10 — Faza 4D: LAYER_DEBUG=0 (rx_meta/tx_mac/eth_txen)

**Kód:** LAYER_DEBUG=0 (normálny mód), L2/L3/L4 promiscuous=1.
**Výsledok:** LED3/4/5 neblikajú. 0/6 echo FAIL. tcpdump: iba PC→FPGA.
**Záver:** rx_meta_valid nevzniká, TX sa nespustí. Gap medzi ipv4_hdr_valid a rx_meta_valid.

---

### Test 11 — Faza 4E (DOKONČENÝ)

**Kód:** RX_PIPE_DEBUG na J10/J11 — všetky RX pipeline štádiá.

**Výsledok (J11 statický):** `01101011` = 0x6B
```
[7]=rx_meta_valid=0, [6]=rx_meta_ready=1, [5]=udp_tlast=1,
[4]=udp_tvalid=1,    [3]=udp_hdr_pre=1,  [2]=ipv4_hdr=1,
[1]=eth_hdr=1,       [0]=frame_done=1
```
**Výsledok (J11 blinking):** `b11b1b11` — rx_meta_valid ([7]) PREBLIKÁ!

**Záver:** RX pipeline kompletne funguje. rx_meta_valid sa generuje správne.
TX chain je záhadne ticho — bug je v TX (echo_app ST_TX_META → pkt_fifo → meta_fifo → TX controller → TX MAC).

---

### Test 12 — Faza 4F TX_PATH_DEBUG (PREBEHOL PRED 4G FIXOM — viz navrhy_22)


**Kód (aktuálny build — kompilacia prebieha 2026-06-01):**
- J11[0]=tx_meta_valid   (echo app ST_TX_META: meta valid)
- J11[1]=tx_meta_ready   (tx_builder ST_IDLE: ready)
- J11[2]=txb_tvalid      (tx_builder outputting bytes)
- J11[3]=txb_fire_w      (byte written to pkt_fifo)
- J11[4]=meta_wr_valid_q (meta committed to meta_fifo)
- J11[5]=pkt_rd_valid    (pkt_fifo non-empty, eth_tx_clk domain)
- J11[6]=meta_rd_valid   (meta_fifo non-empty, eth_tx_clk domain)
- J11[7]=eth_txen_o      (TX MAC transmitting)
- J10 = txb_tdata when txb_tvalid, else pkt_rd_data[7:0], else 0xEE

**Účel:** Pinpointovanie kde sa zastavuje TX chain.

**Interpretácia výsledkov:**
- J11[0]=0: echo_app sa nikdy nedostane do ST_TX_META
- J11[0]=1, J11[1]=0: tx_builder stuck (nie v ST_IDLE)
- J11[1]=1, J11[2]=0: meta handshake OK ale tx_builder nevypisuje
- J11[3]=0: pkt_fifo sa nezapisuje
- J11[4]=0: commit_pending_q nikdy nevzniká
- J11[5]=0: pkt_fifo write OK ale CDC nefunguje (eth_tx_clk problém?)
- J11[5]=1, J11[6]=0: meta_fifo problém
- J11[6]=1, J11[7]=0: TX controller nespustí TX MAC

---

## Implementované zmeny (chronologicky)

### Faza 1-3: TX MAC + základná RX cesta

- gmii_tx_mac, gmii_rx_mac, eth_header_parser, ipv4_header_parser, udp_header_parser
- udp_rx_meta_assembler, udp_echo_app, udp_ipv4_tx_builder
- async_fifo (dual-clock CDC)
- eth_debug_leds

### Faza 4A (2026-05-31)

**gmii_rx_mac.sv — preamble suppression (navrhy_21 záver z HW debug):**
- RX_IDLE: ak `RXDV && rxd==0xD5` → priamo do RX_SFD (nie do RX_PRE)
- Pred tým: iba 0x55 → RX_PRE; RTL8211EG PHY neasertuje RXDV pred SFD

**eth_header_parser.sv — prepis bez packed struct (navrhy_16):**
- Explicitné registre: `dst_mac_q`, `src_mac_q`, `ethertype_q`, `mac_accept_q`
- `mac_accept_q` registrovaný pri byte 5 z `dst_mac_complete_w`
- Nové pulz výstupy: `hdr_done_pulse_o`, `hdr_accept_pulse_o`, `hdr_drop_pulse_o`
- Debug capture: `dbg_dst_mac_o`, `dbg_mac_accept_o`

**eth_debug_leds.sv — MAC_DEBUG mode (navrhy_16/17):**
- Parameter `MAC_DEBUG = 1'b0`
- Nové vstupy: `mac_hdr_done_i`, `mac_accept_i`, `mac_drop_i`
- Toggle sync + stretch counter

**udp_ipv4_tx_builder.sv — 4-CSUM-state redesign (navrhy_19/20):**
- ST_CSUM0-3: každý stav PRESNE 2 operandy (CSA chain eliminovaný)
- ETH_RXC timing: −0.443 ns → +0.448 ns

**ethernet_test_03_top.sv (navrhy_19/20):**
- Debug bus sentinel: `dbg_mac_data_o = mac_tvalid ? mac_tdata : 8'hEE`
- `dbg_ctrl_o[4]` = `dbg_mac_accept_w` (HELD, nie 1-cyc pulz)
- Napojené `dbg_dst_mac_o` a `dbg_mac_accept_o` z parsera

### Faza 4B (2026-05-31)

**ethernet_test_03_top.sv — txb_fire_w CDC fix (navrhy_21):**
- `txb_fire_w = txb_tvalid && txb_tready` — skutočný AXI-S handshake
- `pkt_fifo.wr_valid_i = txb_fire_w`
- `eth/ipv4/udp_header_parser.promiscuous_i = 1'b1` (dočasné)

### Faza 4C (2026-05-31)

**LAYER_DEBUG=1** — overenie L2/L3 cesty cez LED.
Potvrdené: frame_done, eth_hdr_valid, ipv4_hdr_valid fungujú v HW.

### Faza 4E (2026-05-31 — navrhy_22)

**ethernet_test_03_top.sv — RX_PIPE_DEBUG na J10/J11:**
- J11: frame_done, eth_hdr_valid, ipv4_hdr_valid, udp_hdr_pre_valid, udp_tvalid, udp_tlast, rx_meta_ready, rx_meta_valid
- J10: deepest valid layer data mux (udp > ip > eth > mac > 0xEE)
- HW výsledok: J11=0x6B (staticky), rx_meta_valid prebliká → RX pipeline OK

### Faza 4F (2026-06-01 — navrhy_22)

**ethernet_test_03_top.sv — TX_PATH_DEBUG na J10/J11:**
- J11[0..4]: tx_meta_valid, tx_meta_ready, txb_tvalid, txb_fire_w, meta_wr_valid_q (eth_rx_clk)
- J11[5..7]: pkt_rd_valid, meta_rd_valid, eth_txen_o (eth_tx_clk)
- J10: txb_tdata when valid, else pkt_rd_data, else 0xEE

### Faza 4G (2026-06-01, aktuálny build — root cause TX silence)

**Root cause TX silence:** GMII TX kombinačné výstupy (gmii_txd_o, gmii_tx_en_o z
`always_comb`) — RTL8211EG PHY setup Tsu=1.5 ns nebola dodržaná. Kombinačná cesta
state_q FF → mux → I/O buffer trvala ~5-7 ns (8 ns perióda pri 125 MHz).

**gmii_tx_mac.sv — output register fix:**
- Pridané `gmii_txd_comb_w`, `gmii_tx_en_comb_w` (kombinačné)
- Výstupný `always_ff`: `gmii_txd_o <= gmii_txd_comb_w; gmii_tx_en_o <= gmii_tx_en_comb_w`
- CRC vstup zostáva na `gmii_txd_comb_w` (správnosť FCS zachovaná)
- `IFG_BYTES`: 12 → 13 (output FF drží posledný FCS byte počas IFG[0]; PHY vidí iba 12 idle bajtov)
- `PREAMBLE_BYTES`: 7 (nemení sa — output FF delay je transparentný)

**echo_path_top.sv — tx_start race fix (IFG=13):**
- Pridané `logic tx_mac_busy_w;`
- TX MAC: `.tx_busy_o(tx_mac_busy_w)` (bolo `()`)
- TX builder: `.tx_meta_valid_i(tx_meta_valid && !tx_mac_busy_w)` — meta handshake začína až keď MAC idle
- Echo app: `.tx_meta_ready_i(tx_meta_ready && !tx_mac_busy_w)` — echo_app nepostupuje počas IFG
- TX MAC: `.tx_start_i(tx_meta_valid && tx_meta_ready && !tx_mac_busy_w)`
- Dôvod: 1-cyklový tx_start pulz by sa stratil ak MAC ešte v ST_IFG

**Výsledok:** sim regression 16/16 ALL PASS, Quartus timing PASS.

---

## Debug bus J10/J11

```
J10[7:0] = dbg_mac_data_o  → mac_tdata ak mac_tvalid=1, inak 0xEE (sentinel)
J11[0]   = mac_tvalid
J11[1]   = mac_tlast
J11[2]   = frame_done
J11[3]   = hdr_done_pulse  (1-cycle)
J11[4]   = dbg_mac_accept_w (HELD — zachytený po byte 13, drží sa do resetu)
J11[5]   = mac_drop_pulse  (1-cycle)
J11[6]   = eth_rxdv (raw)
J11[7]   = eth_rxer (raw)
```

**Ako čítať:** iba bajty kde `J11[0]=1` sú platné.
Správny RX stream (prvých 14 bajtov):
```
00 0A 35 01 FE C0  E0 4F 43 5B 59 3C  08 00
[dst_mac 6B]       [src_mac 6B]         [ethertype]
```

---

## Otvorené záhady

### Záhada 1: MAC Comparison Bug

**Symptóm:** `hdr_drop_pulse` vždy HIGH, `hdr_accept_pulse` nikdy.
Platí aj po prepise eth_header_parser (Faza 4A).

**PC odosiela:** dst_mac = 00:0a:35:01:fe:c0 (overené tcpdump).
**LOCAL_MAC:** `48'h000A3501FEC0` = 00:0a:35:01:fe:c0.

**Aktuálny stav:** Bypassed cez promiscuous_i=1 (Faza 4B) — diagnóza TX cesty.
**Ďalší krok po overení TX:** Krok 3 z navrhy_21 — rotovať `dbg_dst_mac_w` na J10.

### Záhada 2: TX Silence

**VYRIEŠENÁ (Faza 4G):** Root cause — kombinačné GMII TX výstupy porušovali PHY Tsu=1.5 ns.
Fix: output register v gmii_tx_mac.sv + IFG_BYTES=13 + tx_start race fix v echo_path_top.sv.
**Čaká na HW verifikáciu** s novou 4G SOF.

---

## Stav RTL modulov

| Modul | Súbor | Stav |
|---|---|---|
| `crc32_eth` | `mac/crc32_eth.sv` | PASS — 3/3 |
| `gmii_tx_mac` | `mac/gmii_tx_mac.sv` | PASS — 8/8 |
| `gmii_rx_mac` | `mac/gmii_rx_mac.sv` | PASS sim; PHY preamble fix v HW |
| `eth_header_builder` | `l2/eth_header_builder.sv` | PASS — 3/3 |
| `eth_header_parser` | `l2/eth_header_parser.sv` | PASS sim; MAC comparison HW bug |
| `ipv4_checksum` | `l3/ipv4_checksum.sv` | PASS — 4/4 |
| `ipv4_header_parser` | `l3/ipv4_header_parser.sv` | PASS — 15/15 |
| `udp_header_parser` | `l4/udp_header_parser.sv` | PASS — 21/21 |
| `udp_rx_meta_assembler` | `l4/udp_rx_meta_assembler.sv` | PASS (cez echo_path) |
| `udp_echo_app` | `l4/udp_echo_app.sv` | PASS (cez echo_path) |
| `udp_ipv4_tx_builder` | `l4/udp_ipv4_tx_builder.sv` | PASS — 4-CSUM timing fix |
| `async_fifo` | `cdc/async_fifo.sv` | PASS — FWFT + no_rw_check |
| `ethernet_test_03_top` | `ethernet_test_03_top.sv` | HW testovanie Faza 4F |

---

## Kľúčové RTL rozhodnutia

### hdr_pre_valid_o a _pre porty

`udp_header_parser` vystavuje `hdr_pre_valid_o` (fires pri `byte_cnt==7`).
`udp_rx_meta_assembler` triggeruje priamo — eliminuje 1-cycle edge-detection delay.

### udp_ipv4_tx_builder — 4-CSUM-state redesign

Každý stav PRESNE 2 operandy: `csum_q += {16'd0, ip_word[15:0]}`.
Eliminuje carry-save adder chain (8.359 ns → ~6.7 ns carry chain).

### Dual-clock CDC architektúra

```
RX domain (eth_rx_clk):  gmii_rx_mac -> parsery -> udp_echo_app -> udp_ipv4_tx_builder
                          -> async_fifo.wr_side  (pkt_fifo 9b/2048, meta_fifo 96b/4)
TX domain (eth_tx_clk):  async_fifo.rd_side -> TX FSM -> gmii_tx_mac
```

### txb_fire_w — AXI-S handshake fix

`txb_fire_w = txb_tvalid && txb_tready`. Packet FIFO zapisuje iba pri skutočnom handshake.
Pred fixom: `wr_valid_i=txb_tvalid` — FIFO zapisovalo aj keď builder nebol notifikovaný.

### UDP checksum

TX: 0x0000 (disabled). RX: DROP_NONZERO_CHECKSUM=0.

### Known Issues

- [ ] **HW: MAC comparison bug** — dst_mac comparison failuje v HW napriek sim 12/12 PASS
- [ ] **HW: TX echo neoverené** — čaká na Faza 4G HW test (SOF pripravená)
- [ ] `gmii_rx_mac` FCS strip — dlhodobý cieľ
