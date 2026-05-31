# navrhy_15 — Expertný posudok: dve HW záhady

**Dátum:** 2026-05-30
**Kontext:** eth_test_03 — UDP echo stack, GMII 1Gbps, QMTech EP4CE55 + RTL8211EG

---

## Stručný prehľad

Simulácie: **13/13 PASS** (všetky moduly vrátane dual-clock CDC).
HW: **0% funkčnosť** — FPGA neprijíma ani neodpovedá na UDP pakety.

Progres diagnostiky:
1. GMII RX MAC funguje (frame_done bliká) ← OK
2. eth_header_parser DROPUJE každý frame (s promiscuous=0) ← záhada 1
3. S promiscuous=1 na L2+L3: oba parsery prijímajú ← L3 OK s promiscuous
4. FPGA stále neodpovedá (TX silence) ← záhada 2

---

## Záhada 1: eth_header_parser MAC Comparison zlyhá v HW

### Fakty

**tcpdump (PC strana):**
```
e0:4f:43:5b:59:3c > 00:0a:35:01:fe:c0, IPv4, UDP dport=8080
Hex dst_mac: 00 0a 35 01 fe c0  ← presne LOCAL_MAC
```

**FPGA parameter:**
```sv
parameter logic [47:0] LOCAL_MAC = 48'h000A3501FEC0  // = 00:0a:35:01:fe:c0
```

**drop_decision_w (eth_header_parser.sv:60):**
```sv
assign drop_decision_w = !promiscuous_i &&
                         (header_reg.dst_mac != local_mac_i) &&
                         !(accept_broadcast_i &&
                           (header_reg.dst_mac == ETH_BROADCAST_MAC));
```

**Registrácia dst_mac (eth_header_parser.sv:82-87):**
```sv
4'd0:  header_reg.dst_mac[47:40] <= s_axis_tdata;  // byte 0 = 0x00
4'd1:  header_reg.dst_mac[39:32] <= s_axis_tdata;  // byte 1 = 0x0A
4'd2:  header_reg.dst_mac[31:24] <= s_axis_tdata;  // byte 2 = 0x35
4'd3:  header_reg.dst_mac[23:16] <= s_axis_tdata;  // byte 3 = 0x01
4'd4:  header_reg.dst_mac[15:8]  <= s_axis_tdata;  // byte 4 = 0xFE
4'd5:  header_reg.dst_mac[7:0]   <= s_axis_tdata;  // byte 5 = 0xC0
```

**eth_hdr_t (eth_pkg.sv):**
```sv
typedef struct packed {
  logic [47:0] dst_mac;
  logic [47:0] src_mac;
  logic [15:0] ethertype;
} eth_hdr_t;
```

### Pozorovaný HW výsledok

| Konfigurácia | LED4 (eth_hdr_valid) | Záver |
|---|---|---|
| promiscuous_i=0 | neblikla | drop_decision_w=1 v HW |
| promiscuous_i=1 | blikla | comparison bypasnutý |

### Vylúčené hypotézy

- **Bit reversal RXD**: VYLÚČENÉ — gmii_rx_mac správne deteguje 0x55 (preamble) a 0xD5 (SFD); keby boli bity obrátené, 0xD5 by sa javil ako 0xAB a SFD detekcia by zlyhala
- **Nesprávna MAC na drôte**: VYLÚČENÉ — tcpdump potvrdil `00:0a:35:01:fe:c0`
- **Nesprávny LOCAL_MAC parameter**: VYLÚČENÉ — default 48'h000A3501FEC0 = 00:0a:35:01:fe:c0

### Zostávajúce hypotézy

1. **ETH_RXC timing violation (−0.290 ns slow corner)**: môže spôsobovať bit error v registered `header_reg.dst_mac` → comparison mismatch
2. **Quartus synthesis bug**: packed struct member `header_reg.dst_mac` (48-bit field v 112-bit struct) — iný prístup v `udp_header_parser` (kombinačný shift register `header_next_w`) nemá tento problém
3. **Neznámy HW jav**: niečo v RX dátovej ceste mení bajty

### Porovnanie s udp_header_parser

`udp_header_parser` používa INÝ prístup — kombinačný shift register:
```sv
logic [63:0] header_next_w;
assign header_next_w = {header_reg_q[55:0], s_axis_tdata};
// ...
(!promiscuous_i && (header_next_w[47:32] != local_port_i))
```
Toto NEVYŽADUJE čakanie na registered hodnotu — comparison je nad kombinačnou next hodnotou.
`eth_header_parser` naopak používa REGISTERED `header_reg.dst_mac` pri byte_cnt==13.

### Otázky pre experta

1. Je comparison registered packed struct member voči konštante bezpečný v Quartus Lite 25.1 pre Cyclone IV?
2. Mohol by ETH_RXC timing violation −0.290 ns spôsobiť bit error práve v `header_reg.dst_mac` bitoch?
3. **Navrhovaný fix**: Zmeniť `eth_header_parser` na rovnaký vzor ako `udp_header_parser` — teda vykonávať comparison v `always_ff` (na registered vstupoch) a registrovať výsledok, alebo použiť podobný shift register prístup? Prípadne iné riešenie?

---

## Záhada 2: TX Silence

### Fakty

- S promiscuous=1 na L2 (eth_header_parser) + L3 (ipv4_header_parser): LED4 aj LED5 blikajú
- TCP dump: **žiadna odpoveď od FPGA** — ani jeden Ethernet frame od 00:0a:35:01:fe:c0
- tcpdump filter: `ether host 00:0a:35:01:fe:c0 or udp port 8080` — zachytil by akýkoľvek TX

### Aktuálna kódová verzia (neprogramovaná, čaká na kompiliu)

```sv
// ethernet_test_03_top.sv — aktuálny stav
eth_header_parser: promiscuous_i = 1'b1   // bypasnutý
udp_header_parser: promiscuous_i = 1'b1   // bypasnutý (bezpečnosť)
eth_debug_leds:    LAYER_DEBUG   = 1'b0   // LED3=udp_accept, LED4=tx_busy, LED5=tx_en
```

### Potenciálne príčiny TX silence

**A) L4 (udp_header_parser) — možný drop:**
UDP header parser sa zdá byť v poriadku (kombinačný shift register, nie packed struct comparison).
Ale bez testu nevieme istotu.

**B) TX chain — RTL bug:**
Reťazec: `udp_echo_app → udp_ipv4_tx_builder → pkt_fifo → TX FSM → gmii_tx_mac`
V simulácii: 13/13 PASS vrátane tb_echo_path_dual_clock.
V HW: neznáme — môže byť problém s CDC, async FIFO, alebo TX MAC.

**C) PHY TX hardware:**
RTL8211EG — po reset (PHYRSTB drží LOW 335 ms, potom HIGH).
MDIO je stubovaný (MDC=0, MDIO=Z) — PHY je konfigurovaný len cez hardware strapping.
Keby PHY strapping mal GTX_CLK timing problém alebo TX interný problém, mohol by RX fungovať ale TX nie.

**D) ETH_RXC timing violation v TX builder / echo app:**
Kritická cesta: `udp_echo_app.rx_meta_q.payload_len[1] → u_meta_fifo.mem` −0.282 ns
Toto je PRIAMO v TX ceste — ak meta_fifo nebola správne zapísaná, TX controller sa nikdy nespustí.

### Otázky pre experta

1. Aká je najpravdepodobnejšia príčina TX silence pri 13/13 simulačných PASS?
2. **ETH_RXC timing violation −0.290 ns** — nakoľko je reálne, že ovplyvňuje práve FF→RAM cestu `payload_len → u_meta_fifo.mem`? Ak meta_fifo zápis zlyhá → TX controller sa nikdy nespustí.
3. Je RTL8211EG PHY strapping (bez MDIO) dostatočný pre GMII TX pri 1Gbps? Kde nájsť strapping defaults pre QMTech EP4CE55 board?
4. Navrhovaný postup diagnostiky TX:
   - Krok 1: Sledovať LED3/4/5 v LAYER_DEBUG=0 mode (udp_accept, tx_busy, tx_en)
   - Krok 2: Ak LED3 nesvieti → L4 drop alebo meta assembler bug
   - Krok 3: Ak LED3 svieti ale LED4/5 nie → TX FSM nikdy nespustí
   - Krok 4: Ak LED4/5 svietia → PHY TX hardware problém

---

## Navrhovaný akčný plán (na potvrdenie)

### Fáza A: Diagnostika (aktuálna)
1. Skompilovať + naprogramovať aktuálnu verziu (LAYER_DEBUG=0, všetky promiscuous=1)
2. Spustiť `make udp-test`, sledovať LED3/4/5
3. Podľa výsledku identifikovať problematický blok

### Fáza B: Fix MAC comparison (záhada 1)
Navrhovaný fix — zmeniť `eth_header_parser` na comparison v `always_ff`:
```sv
// Registrovaný výsledok comparison (nie kombinačný nad struct member)
logic dst_mac_match_q;
always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) dst_mac_match_q <= 1'b0;
  else if (s_axis_tvalid && (byte_cnt == 4'd5))  // po poslednom dst_mac bajte
    dst_mac_match_q <= (new_dst_mac == local_mac_i);
end
```
Alebo: refaktorovať na shift register prístup (ako v `udp_header_parser`).

### Fáza C: TX fix (ak je RTL problém)
Závisí od výsledkov Fázy A diagnostiky.

### Fáza D: Timing fix ETH_RXC
Ak −0.290 ns je koreňová príčina, potenciálne riešenia:
- `set_multicycle_path` pre nekritické cesty
- Registrova `drop_decision_w` navyše
- `set_false_path` pre FF→RAM (ak je to propagácia bez timing requirement)

---

## Súbory relevantné pre experta

```
rtl/eth/l2/eth_header_parser.sv     ← záhada 1
rtl/eth/l4/udp_header_parser.sv     ← referenčný (shift register approach)
rtl/eth/eth_pkg.sv                  ← eth_hdr_t struct
rtl/eth/ethernet_test_03_top.sv     ← top-level instantiation
build/rtl/soc_top.sv                ← generated top (parameter passing)
ETH_TEST_03_STATUS.md               ← kompletný stav
navrhy/navrhy_14.md                 ← predchádzajúci expertný posudok
```
