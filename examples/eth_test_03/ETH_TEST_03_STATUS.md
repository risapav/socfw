# ETH_TEST_03 — Status

**Dátum:** 2026-06-05
**Stav:** HW TESTOVANIE — Faza 5A: raw RX trigger → BEACON odpoveď (bypass UDP parserov)

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
- **SOF (Faza 5A):** `output_files/soc_top.sof` — Fri Jun 5 05:23 2026
- **Predchádzajúci SOF:** Faza 4K, Thu Jun 4 15:23 2026 (pkt_rd_valid guard)

### Timing Summary (Faza 4J build, Thu Jun 4 14:48 2026)

| Clock | Slack Setup Slow 85°C | Slack Hold | Stav |
|---|---|---|---|
| ETH_RXC (125 MHz) | **+3.132 ns** | n/a | PASS |
| ETH_TX_CLK (125 MHz) | **+3.753 ns** | n/a | PASS |
| SYS_CLK (50 MHz) | +9.207 ns | n/a | PASS |

**Timing história:**
- Pred fixom: ETH_RXC slack = −7.18 ns (Fmax 65.86 MHz)
- Faza 4A (4-CSUM-state): +0.448 ns PASS
- Faza 4E (RX_PIPE_DEBUG na J11): +0.291 ns PASS
- Faza 4F (TX_PATH_DEBUG na J11): +0.444 ns PASS
- Faza 4G (GMII TX output reg): +0.793 ns PASS (ETH_TX_CLK)
- Faza 4H (Makefile fix, RTL revert): +0.793 ns PASS (nezmeneny RTL)
- Faza 4I (TX beacon + invert_output): +0.895 ns PASS (ETH_TX_CLK improved)
- Faza 4J (meta_fifo DEPTH=32): +3.132/+3.753 ns PASS (ETH_RXC/ETH_TX_CLK výrazne lepší — MLAB)
- Faza 4K (pkt_rd_valid guard): ETH_RXC Fmax=131.82 MHz, ETH_TX_CLK Fmax=139.45 MHz PASS

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
PC: 192.168.0.3 na enp0s31f6 (priame spojenie, 1000Mb/s)
FPGA: LOCAL_IP=192.168.0.2, LOCAL_MAC=00:0a:35:01:fe:c0, UDP_PORT=8080
Static ARP: ip neigh replace 192.168.0.2 lladdr 00:0a:35:01:fe:c0 nud permanent dev enp0s31f6
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

### Test 13 — Faza 4H: MAC comparison diagnostika + Makefile fix (2026-06-02)

**Kód:** MAC_DEBUG=1, promiscuous=1 (dočasné), dbg_mac_data_o = dbg_dst_mac_w[47:40]

**Výsledok MAC_DEBUG (promiscuous=0, normálna build):**
```
LED2: bliká  (RXDV — prijíma rámce)
LED3: bliká  (hdr_done_pulse — parser dosahuje byte 13)
LED4: NEbliká (hdr_accept_pulse — MAC filter VŽDY ZAHODÍ)
LED5: bliká  (hdr_drop_pulse)
```

**J10 PMOD diagnostic (dbg_dst_mac_o[47:40] — prvý byte DST_MAC):**
```
Prvý stav:  J10 = ssssssss = 0x00   (reset / idle)
Po príjme:  J10 = ssnnssnn = 0x33   (lock na 0x33 = IPv6 multicast prefix)
```
*Interpretácia:* `s`=log0, `n`=log1 (PMOD J10 active-low). 0x33 = prvý bajt IPv6 multicast MAC `33:33:xx:xx:xx`.
FPGA dostávala iba IPv6 neighbor discovery multicast, nie unicast UDP.

**Promiscuous bypass test:**
- `promiscuous_i=1'b1` → LED4 príležitostne bliká → MAC comparison logika je správna.

**Root cause (identifikovaný):**
Makefile mal nesprávny `FPGA_IP` a `PC_IFACE`:
```makefile
# WRONG (pred opravou):
FPGA_IP  := 192.168.20.50
PC_IFACE := enp0s20f0u4u1

# CORRECT (po oprave):
FPGA_IP  := 192.168.0.2
PC_IFACE := enp0s31f6
```
PC posielalo UDP pakety na zlú IP adresu cez zlý interface. Skutočné FPGA je pripojené
na `enp0s31f6` s IP `192.168.0.2` / `192.168.0.3` (PC). Cez `enp0s31f6` prichádzali
iba IPv6 multicast rámce (33:33:...) → MAC filter ich správne zahadzoval.

**RTL záver:** `eth_header_parser` MAC comparison je funkčná. Žiadny RTL bug.

**Opravené súbory:**
- `Makefile`: `FPGA_IP=192.168.0.2`, `PC_IFACE=enp0s31f6`
- `test_fpga.py`: reverted na správne defaults (boli správne, len dočasne zmenené)
- `ethernet_test_03_top.sv`: reverted na normálny mód (MAC_DEBUG=0, promiscuous=0, LOCAL_IP=192.168.0.2)
- **Nový build:** Quartus 0 errors, 18 warnings (timing PASS, SOF Tue Jun 2 20:42 2026)

**Čaká:** Programovanie FPGA + `python3 test_fpga.py` → end-to-end UDP echo verifikácia.

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

### Faza 4H (2026-06-02, aktuálny build — MAC comparison diagnostika + Makefile fix)

**Makefile — oprava FPGA_IP a PC_IFACE:**
- `FPGA_IP`: `192.168.20.50` → `192.168.0.2`
- `PC_IFACE`: `enp0s20f0u4u1` → `enp0s31f6`

**test_fpga.py — revert na správne defaults:**
- `FPGA_IP = "192.168.0.2"`, `PC_IFACE = "enp0s31f6"` (defaults boli správne, dočasne zmenené)

**ethernet_test_03_top.sv — revert + btn_i reset port:**
- `LOCAL_IP = 32'hC0A80002` (192.168.0.2)
- `promiscuous_i = 1'b0` (normal MAC filter)
- `MAC_DEBUG=0, CLK_TEST=0, LAYER_DEBUG=0` (debug módy vypnuté)
- `dbg_mac_data_o`: späť na produkčný sentinel (txb_tdata → pkt_rd_data → 0xEE)
- Nový port `btn_i[3:0]` — combined reset: `rst_w = rst_ni & btn_i[3]` (tlačidlo BTN5 ako SW reset)
- Všetky interné `rst_ni` referencie premenované na `rst_w`

**eth_debug_leds.sv — CLK_TEST mode:**
- Nový parameter `CLK_TEST = 1'b0` + `ETH_CLK_HZ = 125_000_000`
- `CLK_TEST=1`: LED2 = ETH_RXC ~1Hz heartbeat, LED3 = ETH_TX_CLK ~1Hz heartbeat
- Účel: verifikácia že oba ETH clock doméns skutočne tečú z PHY/PLL
- CDC: `rx_hb_q` a `tx_hb_q` synchronizované do sys_clk cez cdc_two_flop_synchronizer

**Výsledok:** Quartus 0 errors, 18 warnings, timing PASS.
**Stav:** SOF pripravená, čaká na HW echo test.

### Faza 5A (2026-06-05 — raw RX trigger + UART tap 50B + root cause analýza)

**UART tap rozšírenie (CAPTURE_BYTES: 20 → 50):**
- `ethernet_test_03_top.sv`: `CAPTURE_BYTES(50)` (bol 20)
- `Makefile`: `TAP_BYTES := 50`
- `tools/read_tap.py`: pridaná dekódovacia funkcia pre UDP hlavičku (sport/dport/len)
- Výstup `make tap-test`: viditeľný Frame 1, UDP length=13 (HELLO), "HELLO" payload potvrdený

**UART tap analýza — 1-bajt offset potvrdený:**
```
Frame 1 raw bytes (50):
  0a 25 01 ee de 98 fa 9b 3a bf 1c 08 00 45 00 00 21 a7 dd 42
  00 40 11 01 99 c0 a8 00 03 c0 a8 00 02 b3 e5 1f 9f 00 0d c7
  76 48 45 4c 4c 4f 0e 00 00 00

Interpretácia (s 1-bajt offsetom — bajt[0] = ETH[1]):
  SRC MAC [5:10]  = 98:fa:9b:3a:bf:1c (PC MAC — presná zhoda!)
  EtherType [11:12] = 08 00 = IPv4
  IP SRC [25:28]  = c0 a8 00 03 = 192.168.0.3
  IP DST [29:32]  = c0 a8 00 02 = 192.168.0.2
  UDP sport [33:34] = b3 e5 = 46053
  UDP dport [35:36] = 1f 9f ≈ 8080 (mierna korupcia)
  UDP len  [37:38] = 00 0d = 13 (8+5 = HELLO) ✓
  Payload  [41:45] = 48 45 4c 4c 4f = "HELLO" ✓
```

**Root cause: 1-bajt offset v gmii_rx_mac výstupe → wrong payload_len_q**

Parsery dostávajú stream posunutý o 1 bajt (ETH DST MAC[0]=0x00 sa neprenesie):
- `eth_header_parser` strip 14B → IP parseru: bajty od ETH[15] (nie ETH[14])
- `ipv4_header_parser` strip 20B → UDP parseru: bajty od ETH[35] (nie ETH[34])
- `udp_header_parser` číta UDP dĺžku z ETH[39:40]:
  - `len_b0_q` ← ETH[39] = 0x0d (UDP length low byte)
  - `len_b1_q` ← ETH[40] = 0xc7 (UDP checksum high byte — NESPRÁVNE!)
  - `payload_len_q = {0x0d, 0xc7} - 8 = 0x0DC7 - 8 = 3519`

FPGA čaká 3519 payload bajtov, rámec skončí po 5 → tlast NIKDY → `latch_udp_tlast=0`.

**Prečo 1-bajt offset?**
RTL analýza `gmii_rx_mac` hovorí: DST_MAC[0]=0x00 SA MÁ objaviť ako prvý bajt.
HW ukazuje 0x0a (DST_MAC[1]). Príčina: pravdepodobne timing GMII IOE, reset CDC
alebo niečo iné v `eth_stream_tap` FIFO. Vyžaduje ďalšiu analýzu.

**Faza 5A — raw RX trigger (bypass UDP parserov):**
- `ethernet_test_03_top.sv`: toggle-CDC `mac_tvalid && mac_tlast` → eth_tx_clk edge detect
- Keď `raw_rx_pulse_w` fires v TXC_IDLE: okamžite `bcn_pending_q = 1'b1`
- FPGA odošle BEACON (broadcast, 0xBEAC) na KAŽDÝ prijatý Ethernet rámec
- Účel: verify že RX detekcia → TX triggering funguje BEZ parserov
- Ak BEACON viditeľný v pcap po odoslaní UDP paketu → potvrdzuje že TX chain OK

**Timing Faza 5A:** ETH_RXC Fmax ≈131 MHz, 55 CDC chains, 0 errors. ✓

### Faza 4K (2026-06-04 — meta_fifo DEPTH=32 + pkt_rd_valid guard — HOTOVO)

**Root cause identifikovaný (navrhy_23 + beacon test analýza):**

meta_fifo `async_fifo #(.DATA_WIDTH(96), .DEPTH(4))` — 4×96=384 bits je príliš malé
pre Quartus aby inferoval ako dual-clock block RAM → Quartus vytvára FF-based logiku:
`mem[0..3]` FFs sú v `wr_clk` (eth_rx_clk_i) doméne ale `rd_data_q <= mem[rptr]`
sa číta z `rd_clk` (eth_tx_clk_i) doméne = raw cross-domain data path bez synchronizácie!

**Dôkaz:** Quartus compile warnings — `Inferred dual-clock RAM` pre pkt_fifo a tap_fifo,
ALE NIE pre meta_fifo. s DEPTH=32 (3072 bits): Quartus inferencuje `altsyncram_ffe1` (MLAB).

**Faza 4J zmeny (`ethernet_test_03_top.sv`):**
- `u_meta_fifo DEPTH`: 4 → 32 (force MLAB inference)
- Quartus: meta_fifo teraz `altsyncram:mem_rtl_0|altsyncram_ffe1` ✓
- Timing: ETH_RXC +3.1ns, ETH_TX_CLK +3.8ns PASS

**Faza 4K zmeny (`ethernet_test_03_top.sv`, pridané k 4J):**
- TXC_IDLE: `meta_rd_valid && !tx_mac_busy_w` → `meta_rd_valid && pkt_rd_valid && !tx_mac_busy_w`
- `meta_rd_ready`: rovnaká zmena — FIFO dequeued len keď pkt_rd_valid tiež
- Dôvod (navrhy_25): meta sa zapisuje AŽ PO poslednom pkt byte, takže meta_rd_valid
  musí nastať po pkt_rd_valid. Ale CDC gray-code sync paths sú nezávislé — ordering
  nie je garantovaný v TX doméne. Guard zabraňuje TX FSM štartovaniu bez payloadu.

**Timing Faza 4K:** ETH_RXC Fmax=131.82 MHz, ETH_TX_CLK Fmax=139.45 MHz, 0 errors. ✓

---

### Faza 4I (2026-06-04 — TX beacon + GTxCLK invert fix)

**ethernet_test_03_top.sv — TX beacon v TXC FSM:**
- Beacon idle counter (27-bit, ~1.07 s pri 125 MHz): `bcn_cnt_q`
- `bcn_pending_q`: nastavený po pretečení, vyčistený pri štarte beaconu
- `bcn_fire_w`: kombinačná podmienka pre beacon TX
- `bcn_mode_q`: 1 = aktuálny TX je beacon (nie echo reply)
- `bcn_byte_q`: 0=prvý byte (0xBE), 1=druhý byte (0xAC)
- TXC_IDLE: `bcn_fire_w` spustí broadcast frame (DST=FF:FF:FF:FF:FF:FF, SRC=LOCAL_MAC)
- TXC_DATA v bcn_mode: servíruje 2 bajty, gmii_tx_mac dopĺňa padding + FCS
- `pkt_rd_ready`: gated na `!bcn_mode_q` (echo a beacon sa navzájom nevyrušujú)
- Účel: ak beacon viditeľný v pcap → GMII TX funguje; ak ticho → GTxCLK/PCB issue

**altddio_out invert_output: OFF → ON:**
- Pred: GTxCLK = eth_tx_clk_i → 0 ns setup time (spec: 2 ns min) — nevyhovujúce
- Po: GTxCLK = ~eth_tx_clk_i → T/2 = 4 ns setup time — spec splnená
- Fitter: `ddio_out_r6j` (invert variant) na PIN_U22, Bank 5, Row I/O ✓

**diag.sh — nové diagnostické sekcie:**
- [1b] Link speed: ethtool kontrola 1Gbps vs 100Mbps
- [5/5] NIC CRC diff: `ethtool -S` baseline vs. post-test
  (odhaľuje bad-FCS frames zahodené NIC hardvérom pred tcpdumpom)

**Výsledok:** Quartus compile 0 errors, timing PASS. SOF 2026-06-04.

### Faza 4G (2026-06-01 — root cause TX silence)

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

## Debug bus J10/J11 (Faza 4I, aktuálny mód — sticky latches)

```
J10[7:0] = dbg_mac_data_o  → txb_tdata ak txb_tvalid=1,
                              inak pkt_rd_data[7:0] ak pkt_rd_valid=1,
                              inak dbg_dst_mac_w[15:8] (DST_MAC byte4 = 0xFE pri FPGA MAC)
J11[7]   = latch_tx_busy_q   [TX-STICKY] gmii_tx_mac bol aktivny (GMII TX na drate)
J11[6]   = latch_meta_wr_q   [RX-STICKY] meta FIFO write prebehol
J11[5]   = latch_txb_fire_q  [RX-STICKY] TX builder vypalil aspon 1 byte
J11[4]   = latch_tx_meta_q   [RX-STICKY] echo_app dokoncil RX, vstupil do TX_META
J11[3]   = latch_rx_meta_q   [RX-STICKY] UDP meta OK, parsery funguju
J11[2]   = latch_udp_tvalid_q [RX-STICKY] udp_parser emitoval payload byte
J11[1]   = latch_udp_tlast_q  [RX-STICKY] udp_parser vypalil tlast
J11[0]   = tx_meta_valid      [RX-LIVE]  echo_app je teraz v ST_TX_META
```

**Interpretácia:**
- `J11=nnnnnnns` → PLNÁ PIPELINE, gmii_tx_mac aktivny (ale TX stále ticho → GTxCLK issue)
- `J11=sxxxxxxx` → gmii_tx_mac sa NIKDY nespustil
- `J10=0xFE` pri idle → DST_MAC byte4 správny (FPGA MAC prijaté)
- `J10=0x16` (pozorované 2026-06-03) → pkt_rd_data viditeľné v TX domene
  (pkt_fifo má dáta z ďalšieho paketu, TXC IDLE čaká)

---

## Výsledky HW testovania — Chronológia (2026-06-03)

### Test 15 — Faza 4I: TX beacon VIDITEĽNÝ, echo 0/6 (2026-06-04)

**Podmienky:** Faza 4I SOF, Link 1000Mb/s, fresh FPGA reset pred testom.

**diag.sh výsledok:**
```
[1b] Link: yes   Speed: 1000Mb/s   Duplex: Full -> OK
[5/5] Frames od FPGA: 8 (iba beacony)
  FPGA odosielalo! Prvy frame: 00:0a:35:01:fe:c0 > Broadcast, ethertype IPv4, length 60
  payload: ffff ffff ffff 000a 3501 fec0 0800 beac (0xBEAC)
  Beacony každých ~1.07s (= 2^27 / 125MHz)
  ECHO: 0/6 PASS — žiadna odpoveď
J11 = nsssnnss
  bit7=1 latch_tx_busy=1    TX MAC aktívny (beacon)
  bit6=0 latch_meta_wr=0    meta FIFO nikdy zapísaný
  bit5=0 latch_txb_fire=0   TX builder nikdy nevypálil
  bit4=0 latch_tx_meta=0    echo_app nikdy v ST_TX_META
  bit3=1 latch_rx_meta=1    UDP meta OK
  bit2=1 latch_udp_tvalid=1 payload bytes prijaté
  bit1=0 latch_udp_tlast=0  TLAST NIKDY!
  bit0=0 tx_meta_valid=0
J10 = 0x16 (pkt_rd_data viditeľné v TX domene)
```

**Beacon analýza:**
- Beacon fires každých ~1.07s, **NEPRERUŠOVANÉ** UDP paketmi → meta_rd_valid = 0 vždy v TX domene
- Beacon timer sa resetuje keď meta_rd_valid=1; ak by meta fungovalo, timer by sa resetoval
- **Root cause: meta_fifo CDC broken** (vid. sekciu nižšie)

**GMII TX overené:** GMII TX fyzická cesta FUNGUJE. GTxCLK OK. invert_output="ON" správne.

---

### Test 16 — Faza 4I, fresh reset, link DOWN (2026-06-04)

**Podmienky:** FPGA resetnutý bezprostredne pred testom (sticky latche vyčistené).
Link DOWN (ethtool: "Link: no") — PHY po resete ešte nenegocioval (PHYRSTB timer 336ms).

**diag.sh výsledok:**
```
[1b] Link: no   Speed: Unknown!   -> LINK DOWN (PHY po resete, nie hardware bug!)
[5/5] Frames od FPGA: 8 (beacony — z pred-link doby)
J11 = nsssnnss (rovnaké ako Test 15 — fresh latche)
  bit1=0 latch_udp_tlast=0  POTVRDENÉ: aj s fresh latch stav = 0
```

**Záver:** `latch_udp_tlast=0` nie je link-drop artefakt — je to skutočný stav.
Link DOWN bol len pretože test beží príliš skoro po resete (PHYRSTB timer + link negotiation ~3-5s).
**Instrukcia:** Po FPGA resete čakaj 5 sekúnd pred spustením diag.sh.

---

### Test 14 — Faza 4H SOF: plná pipeline, TX stále ticho

**Podmienky:** Link 1Gbps Full Duplex (potvrdené ethtool), promiscuous=1 (všetky parsery).

**diag.sh výsledok:**
```
[1b] Link: yes   Speed: 1000Mb/s   Duplex: Full  -> OK
[5/5] Frames od FPGA: 0
      NIC CRC/FCS chyby: bez zmeny (FPGA neposiela ani bad-FCS frames)
J11 = nnnnnnns (hex: všetky sticky bity = 1)
J10 = sssnsnns (hex: 0x16)
```

**J11 decode:**
```
bit7 latch_tx_busy_q  = 1  [TX-STICKY]  gmii_tx_mac sa aktivoval
bit6 latch_meta_wr_q  = 1  [RX-STICKY]  meta FIFO write ok
bit5 latch_txb_fire_q = 1  [RX-STICKY]  TX builder vypalil byte
bit4 latch_tx_meta_q  = 1  [RX-STICKY]  echo_app do TX_META
bit3 latch_rx_meta_q  = 1  [RX-STICKY]  UDP meta ok
bit2 latch_udp_tvalid = 1  [RX-STICKY]  udp_parser payload byte
bit1 latch_udp_tlast  = 1  [RX-STICKY]  udp_parser tlast
bit0 tx_meta_valid    = 0  [RX-LIVE]    echo_app nie je v ST_TX_META
```

**Záver:** PLNÁ PIPELINE prebehla — RX aj TX chain sú logicky funkčné.
FPGA tvrdí že gmii_tx_mac vysielal (latch_tx_busy=1). Ale NUL frames na wire.
Ani bad-FCS frames (NIC CRC counters bez zmeny). PHY nereaguje na GMII TX vôbec.

---

## Investigácie — ČO SME UŽ OVERILI (neopakovať)

### 1. Link speed — OVERENÉ OK
`ethtool enp0s31f6` → 1000Mb/s Full Duplex. Nie 100Mbps (MII 25MHz) problém.

### 2. NIC CRC/FCS chyby — OVERENÉ: žiadne
`ethtool -S enp0s31f6` baseline vs. post-test = beze zmeny.
FPGA neposiela ANI garbled frames. PHY vôbec nevysiela na drôt.

### 3. latch_tx_busy_q = 1 — OVERENÉ
Registered v eth_tx_clk_i domain (125MHz PLL output = clkpll_c0).
Potvrdzuje: PLL beží, TXC FSM opustil TXC_IDLE, gmii_tx_mac prešiel z ST_IDLE.

### 4. CRC logika — OVERENÁ správna
`crc32_eth.sv`: LSB-first, polynomial 0xEDB88320, init 0xFFFFFFFF, fcs_o = ~crc_reg.
CRC vstup: `gmii_txd_comb_w` (combinational pred output FF) = správny byte.
IFG_BYTES=13 (+1 pre output FF delay na poslednom FCS byte) = správne.

### 5. eth_header_builder byte order — OVERENÝ
`dst_mac[47:40]` = byte 0 (prvý na drôt). Network byte order. Správne.

### 6. soc_top.sv connection — OVERENÁ
`.eth_gtx_clk_o(ETH_GTX_CLK)` → priamo na top-level port → PIN_U22. Správne.
Wire `ethernet_test_03_top_eth_gtx_clk_o` deklarovaný ale unconnected — benígny leftover.

### 7. altddio_out invert_output — ZMENENÉ v tejto session
Pred: `invert_output("OFF")` → GTxCLK = eth_tx_clk_i → 0ns setup time na PHY (spec 2ns min).
Po: `invert_output("ON")` → GTxCLK = ~eth_tx_clk_i → T/2 = 4ns setup time. Správne.
Fitter potvrdil: `ddio_out_r6j` (invert variant) na PIN_U22. Warning 15064 = 0. OK.
**Ale TX stále ticho po tejto zmene.**

### 8. pkt_fifo / meta_fifo CDC — OVERENÉ logicky
J11 plná pipeline (latch_meta_wr=1 aj meta_rd: TXC FSM videl meta_rd_valid).
CDC async_fifo 2-FF Gray-code synchronizer — štandardná implementácia. OK.

### 9. PHYRSTB timing — OVERENÉ
24-bit counter @ 50MHz → 336ms reset delay. PHY released pred linkupom (>500ms).
RX funguje = PHY z resetu správne.

### 10. gmii_tx_mac output registers — OVERENÉ
`always_ff` registered `gmii_txd_o`, `gmii_tx_en_o` from `*_comb_w`.
`FAST_OUTPUT_REGISTER ON` v board.tcl pre ETH_TXD[7:0] a ETH_TXEN. PIN_V21, Bank 5. OK.

### 11. Fitter report ETH_GTX_CLK — OVERENÝ
PIN_U22, Bank 5, Row I/O, Output Register = "yes" (DDR in IOE). Placed in IOE. OK.

---

## Aktuálna situácia: GMII TX fyzicky funguje, echo nefunguje

**Stav po Faze 4I (2026-06-04):**
- GMII TX OK: beacony viditeľné v pcap ✓ (GTxCLK, PHY, wire)
- Echo 0/6: meta_fifo CDC broken (meta_rd_valid = 0 vždy v TX doméne)
- Root cause: DEPTH=4 → FF-based mem v wr_clk čítané z rd_clk
- Fix v Faze 4K: DEPTH=32 + pkt_rd_valid guard — SOF Thu Jun 4 15:23 2026 ✓

---

## Otvorené záhady

### Záhada 1: MAC Comparison Bug — VYRIEŠENÁ (Faza 4H)

**Root cause:** Makefile mal nesprávny `FPGA_IP=192.168.20.50` a `PC_IFACE=enp0s20f0u4u1`.
PC nikdy neposlalo UDP na správnu adresu cez správny interface. FPGA dostávala iba IPv6
multicast (33:33:...) ktoré MAC filter správne zahadzoval.

**RTL je SPRÁVNY.** `eth_header_parser` MAC comparison funguje — potvrdené:
1. J10 PMOD: prvý DST_MAC byte = 0x33 (IPv6 multicast, nie 0x00 = náš MAC)
2. Promiscuous bypass: LED4 blikala → logika comparison path je funkčná

**Fix:** `Makefile` opravený na `FPGA_IP=192.168.0.2`, `PC_IFACE=enp0s31f6`.

### Záhada 2: TX Silence — PREBIEHA (Faza 4I)

Root cause stále neznámy. Pôvodná hypotéza (Faza 4G: kombinačné GMII TX výstupy)
**NEVYRIEŠILA problém** — latch_tx_busy=1 ale 0 frames na wire.

**Aktuálna teória:** GTxCLK nedochádza k PHY (altddio_out / PCB trace issue).

**Faza 4I (2026-06-04):** TX beacon pridaný do TXC FSM:
- Ked TXC IDLE > ~1s bez echo requestu: fire broadcast frame (DST=FF:FF:FF:FF:FF:FF,
  SRC=LOCAL_MAC, payload=0xBE 0xAC)
- Ak beacon v pcap → GMII TX fyzická cesta funguje (problém je inde)
- Ak beacon ticho → GTxCLK/PHY/PCB broken

**Interpretácia výsledkov beacon testu:**
```
Beacon visible in tcpdump (ether host FPGA_MAC filter):
  -> GMII TX wire OK, GTxCLK OK
  -> Hľadaj bug v echo CDC ceste alebo frame obsahu
Beacon NOT visible:
  -> GTxCLK nedochádza k PHY
  -> Ďalší krok: bypass altddio_out (assign eth_gtx_clk_o = eth_tx_clk_i)
     alebo osciloskop na PIN_U22
```

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
| `ethernet_test_03_top` | `ethernet_test_03_top.sv` | HW testovanie Faza 4H (caka echo test) |

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
                          -> async_fifo.wr_side  (pkt_fifo 9b/2048, meta_fifo 96b/32)
TX domain (eth_tx_clk):  async_fifo.rd_side -> TX FSM -> gmii_tx_mac
```

**POZOR CDC pitfall:** async_fifo s malou DEPTH (< ~16 entries pre 96-bit data) sa
nevyinferencuje ako dual-clock block RAM v Quartus Cyclone IV → stáva sa FF logika
kde `mem[]` FFs sú v wr_clk doméne ale sú čítané z rd_clk = raw CDC data path violation.
Fix: DEPTH ≥ 32 pre 96-bit data → Quartus MLAB inference (altsyncram_ffe1).

### txb_fire_w — AXI-S handshake fix

`txb_fire_w = txb_tvalid && txb_tready`. Packet FIFO zapisuje iba pri skutočnom handshake.
Pred fixom: `wr_valid_i=txb_tvalid` — FIFO zapisovalo aj keď builder nebol notifikovaný.

### UDP checksum

TX: 0x0000 (disabled). RX: DROP_NONZERO_CHECKSUM=0.

### Known Issues

- [x] **HW: MAC comparison bug** — VYRIEŠENÁ (Faza 4H): Makefile mal zlý FPGA_IP/PC_IFACE; RTL je správny
- [x] **HW: GMII TX ticho** — VYRIEŠENÁ (Faza 4G + 4I): gmii_tx_mac output registers + GTxCLK invert_output="ON"
  - Beacon frames viditeľné v pcap (Test 15) → GMII TX, GTxCLK, PHY fungujú ✓
- [ ] **HW: meta_fifo CDC** — Faza 4K SOF (Thu Jun 4 15:23 2026) čaká na HW test
  - Root cause: DEPTH=4 (384 bits) — Quartus nevytvára dual-clock RAM → FF v wr_clk doméne čítané z rd_clk
  - Fix: DEPTH=32 → Quartus MLAB altsyncram_ffe1 (dual-clock RAM) ✓
  - Symptóm: meta_rd_valid = 0 vždy v TX doméne (beacon timer nikdy nepreruší)
  - Zostatok: `latch_udp_tlast=0` — udp_parser tlast nikdy nevypálil
    → Pravdepodobná príčina: link DOWN pri teste (PHY po resete) alebo skutočný bug
    → Overiť s Faza 4K SOF + stabilný link (čakaj 5s po FPGA resete)
- [ ] `gmii_rx_mac` FCS strip — dlhodobý cieľ
