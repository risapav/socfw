Tento status je dobrý, ale má v sebe pár vnútorných nesúladov, ktoré by som opravil, aby bol použiteľný ako reálny pracovný checkpoint.

## 1. Najväčší nesúlad v statuse

V hornej časti píšeš:

```text
tb_gmii_tx_mac — PASS (8/8)
tb_gmii_rx_mac — PASS (5/5)
```

ale v tabuľke RTL modulov je stále:

```text
gmii_tx_mac | Prepísaný (fix padding), čakáme na tb PASS
gmii_rx_mac | Prepísaný (fix SFD — RX_SFD stav), čakáme na tb PASS
```

To už treba zmeniť na:

```text
gmii_tx_mac | PASS — unit test 8/8
gmii_rx_mac | PASS — unit test 5/5
```

Čiže aktuálny stav projektu by som formuloval takto:

```text
MAC vrstva je unit-testovo uzavretá pre základný TX/RX prípad.
Ďalší blocker je L2 parser, nie GMII MAC.
```

---

## 2. Aktualizovaná tabuľka stavu modulov

Navrhol by som prepísať tabuľku takto:

| Modul                  | Súbor                              | Stav                                            |
| ---------------------- | ---------------------------------- | ----------------------------------------------- |
| `crc32_eth`            | `rtl/eth/mac/crc32_eth.sv`         | PASS                                            |
| `gmii_tx_mac`          | `rtl/eth/mac/gmii_tx_mac.sv`       | PASS, základný TX frame/padding/FCS/IFG overený |
| `gmii_rx_mac`          | `rtl/eth/mac/gmii_rx_mac.sv`       | PASS, SFD stripping/tlast/data overené          |
| `eth_header_builder`   | `rtl/eth/l2/eth_header_builder.sv` | Neoverený, jednoduchý unit test doplniť         |
| `eth_header_parser`    | `rtl/eth/l2/eth_header_parser.sv`  | Treba opraviť stale `hdr_valid` / byte 13       |
| `ipv4_checksum`        | `rtl/eth/l3/ipv4_checksum.sv`      | Neoverený, doplniť TB                           |
| `ipv4_header_parser`   | `rtl/eth/l3/ipv4_header_parser.sv` | Treba opraviť `header_next_w`, UDP filter       |
| `udp_header_parser`    | —                                  | CHÝBA                                           |
| `udp_echo_app`         | `rtl/eth/app/udp_echo_app.sv`      | Treba latch metadata, handshake, overflow       |
| `ethernet_test_03_top` | `rtl/ethernet_test_03_top.sv`      | Zatiaľ neuzatvárať, kým neprejdú L2/L3/L4       |

---

## 3. Čo znamená „MAC vrstva PASS“

Toto je dôležité dobre pomenovať. Aktuálne máš overené:

```text
crc32_eth:
  CRC výpočet sedí

gmii_tx_mac:
  preambula/SFD
  Ethernet TX frame length
  padding
  FCS
  IFG
  tx_er = 0

gmii_rx_mac:
  SFD sa neobjavuje na výstupe
  prvý dátový byte je správny
  tlast je na poslednom byte
  počet a obsah bajtov sedí
```

To je dobrý míľnik.

Ale ešte to neznamená:

```text
stream -> tx -> rx -> stream PASS
rx -> stream -> tx PASS
UDP echo PASS
```

Tieto testy sú až integračné. Teraz máš overené stavebné kamene MAC, nie ich spoločné prepojenie.

---

## 4. Odporúčané ďalšie poradie práce

Nepreskakoval by som rovno na celý UDP echo path. Teraz by som išiel presne po vrstvách.

### Krok A — uzavrieť L2

Najbližšie sprav:

```text
tb_eth_header_builder
tb_eth_header_parser
```

Pre `eth_header_builder` testuj presné bajty:

```text
dst = DE AD BE EF 12 34
src = 00 0A 35 01 FE C0
ethertype = 08 00

očakávanie:
DE AD BE EF 12 34 00 0A 35 01 FE C0 08 00
```

Pre `eth_header_parser` testuj:

```text
1. unicast na local MAC -> payload prejde
2. broadcast -> prejde, ak accept_broadcast_i=1
3. wrong MAC -> drop
4. dva frame za sebou -> parser sa resetne do header stavu
5. EtherType sa vyparsuje správne
```

A oprav stale bug cez `header_next_w`.

---

### Krok B — stream/TX/RX MAC integračný test

Keď L2 builder/parser prejde, hneď by som pridal test:

```text
tb_mac_stream_tx_rx_stream
```

Schéma:

```text
payload stream
  -> gmii_tx_mac
  -> gmii_rx_mac
  -> stream scoreboard
```

Toto overí, že TX a RX MAC spolu sedia, nielen samostatne.

Očakávanie pre čistý MAC test s payloadom `"HELLO"`:

```text
TX MAC payload_len = 5

GMII TX:
  7x55 D5
  Ethernet header 14 B
  HELLO 5 B
  padding 41 B
  FCS 4 B

RX MAC stream:
  Ethernet header 14 B
  HELLO 5 B
  padding 41 B
```

Ak RX MAC zatiaľ neodstraňuje FCS, test treba upraviť podľa aktuálnej politiky. Cieľovo by som však chcel, aby RX MAC výstup bol bez FCS.

---

### Krok C — IPv4 vrstva

Potom rieš:

```text
tb_ipv4_checksum
tb_ipv4_header_parser
```

Pri `ipv4_header_parser` oprav:

```systemverilog
logic [159:0] header_next_w;

assign header_next_w = {header_reg[151:0], s_axis_tdata};
```

a validuj až z `header_next_w`:

```systemverilog
hdr_valid_int <=
  (header_next_w[159:152] == 8'h45) &&
  (header_next_w[79:72]   == eth_pkg::IPV4_PROTO_UDP) &&
  (header_next_w[31:0]    == local_ip_i);
```

Minimálne validácie:

```text
version/IHL == 0x45
protocol == UDP / 0x11
dst_ip == LOCAL_IP
total_length >= 20
```

---

### Krok D — UDP parser

Vytvor:

```text
rtl/eth/l4/udp_header_parser.sv
```

Rozhranie by malo byť streamové:

```systemverilog
module udp_header_parser (
  input  wire logic        clk_i,
  input  wire logic        rst_ni,

  input  wire logic [15:0] local_port_i,
  input  wire logic        promiscuous_i,

  input  wire logic [7:0]  s_axis_tdata,
  input  wire logic        s_axis_tvalid,
  output      logic        s_axis_tready,
  input  wire logic        s_axis_tlast,
  input  wire logic        s_axis_tuser,

  output      logic [7:0]  m_axis_tdata,
  output      logic        m_axis_tvalid,
  input  wire logic        m_axis_tready,
  output      logic        m_axis_tlast,
  output      logic        m_axis_tuser,

  output      logic [15:0] src_port_o,
  output      logic [15:0] dst_port_o,
  output      logic [15:0] udp_len_o,
  output      logic [15:0] payload_len_o,
  output      logic        hdr_valid_o,
  output      logic        drop_o
);
```

Testy:

```text
valid UDP port 8080 -> payload prejde
wrong dst port -> drop
udp_len < 8 -> drop
payload_len = udp_len - 8
dva UDP pakety za sebou
```

---

### Krok E — `udp_echo_app`

Opravy:

```text
1. latchnúť rx_meta_i do rx_meta_q
2. latchnúť payload_len_q
3. zapisovať iba pri s_axis_tvalid && s_axis_tready
4. čítať iba pri m_axis_tvalid && m_axis_tready
5. m_axis_tlast = m_axis_tvalid && last_byte
6. overflow guard
```

Metadata treba otočiť z latchnutého `rx_meta_q`, nie priamo z `rx_meta_i`.

---

### Krok F — integračné testy

Až potom:

```text
tb_l2_rx_stream_tx_replay
tb_l2_l3_udp_rx_path
tb_udp_echo_full_path
```

Tvoj cieľový full path:

```text
GMII RX
 -> gmii_rx_mac
 -> eth_header_parser
 -> ipv4_header_parser
 -> udp_header_parser
 -> udp_echo_app
 -> UDP/IP builders
 -> gmii_tx_mac
 -> GMII TX
```

---

## 5. Doplnenie do otvorených úloh

Do statusu by som pridal ešte tieto položky:

```text
8. Pridať tb_eth_header_builder
9. Pridať tb_mac_stream_tx_rx_stream
10. Pridať tb_l2_rx_stream_tx_replay
11. Rozhodnúť politiku gmii_rx_mac: výstup s FCS alebo bez FCS
12. Pridať ipv4_header_builder a udp_header_builder pre TX cestu
13. Pridať eth_debug_leds.sv alebo dočasne odstrániť z topu
```

Najmä bod 11 je dôležitý. Pre knižnicu odporúčam:

```text
gmii_rx_mac výstup = Ethernet frame bez preambuly/SFD a bez FCS
```

Ale ak ho zatiaľ necháš s FCS, musí to byť explicitne v dokumentácii aj testoch.

---

## 6. Upravený stav projektu jednou vetou

Navrhol by som do statusu dať:

```text
MAC vrstva je unit-testovo PASS. Nasleduje uzatvorenie L2 parserov a prvé MAC integračné testy stream→TX→RX→stream a RX→stream→TX. Full UDP echo top zatiaľ nie je cieľom aktuálnej fázy.
```

To presne vystihuje stav a zabráni tomu, aby sa príliš skoro debugoval top, ktorý ešte nemá dokončené L2/L3/L4 bloky.

---

## 7. Najbližší konkrétny checklist

Najbližší commit by som zameral na:

```text
[ ] opraviť tabuľku statusu — gmii_tx_mac/gmii_rx_mac sú PASS
[ ] pridať tb_eth_header_builder
[ ] opraviť eth_header_parser cez header_next_w
[ ] pridať tb_eth_header_parser
[ ] pridať tb_mac_stream_tx_rx_stream
[ ] opraviť ipv4_header_parser cez header_next_w
[ ] pridať tb_ipv4_checksum
[ ] pridať tb_ipv4_header_parser
```

Až potom by som začal písať `udp_header_parser`.

Vývoj ide správnym smerom. Najväčší úspech aktuálneho stavu je, že MAC vrstva už má reálne testy a tie prechádzajú. Teraz treba rovnako disciplinovane uzavrieť L2, L3 a L4.
