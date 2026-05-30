Tu sú moje odporúčania pre štyri otvorené otázky. Bral by som ich ako rozhodnutia pre architektúru `eth_test_03`, nie iba ako lokálne opravy.

# 1. FCS politika

Odporúčam túto finálnu politiku:

```text
gmii_rx_mac výstup:
  Ethernet frame bez preambuly/SFD a bez FCS

gmii_tx_mac vstup:
  Ethernet payload bez FCS

gmii_tx_mac výstup:
  pridá preambulu, SFD, Ethernet header, padding, FCS a IFG
```

Čiže FCS má zostať výhradne v MAC vrstve.

## Prečo

Vyššie vrstvy nemajú vedieť o FCS. `eth_header_parser`, `ipv4_header_parser`, `udp_header_parser` by mali dostať čisté dáta bez fyzickej/MAC trailer logiky. Inak musí každý vyšší parser riešiť, že na konci rámca môžu byť padding + FCS, čo komplikuje L3/L4.

## Aktuálny prechodný stav

Teraz `gmii_rx_mac` podľa statusu posiela ďalej aj FCS:

```text
gmii_rx_mac output = Ethernet header + payload + padding + FCS
```

To je akceptovateľné iba dočasne. Ak to necháš tak, `udp_header_parser` musí podľa `udp_len` forwardovať iba UDP payload a zvyšok do `s_axis_tlast` zahodiť:

```text
UDP header + UDP payload + Ethernet padding + FCS
                   ^ forwardovať iba toto podľa udp_len - 8
```

Ale cieľovo by som `gmii_rx_mac` upravil na:

```text
STRIP_FCS = 1
CHECK_FCS = voliteľne 0/1
```

Navrhované parametre:

```systemverilog
parameter bit STRIP_FCS = 1'b1;
parameter bit CHECK_FCS = 1'b0;
```

Pre prvú knižničnú verziu:

```text
STRIP_FCS = 1
CHECK_FCS = 0
```

Pre neskoršiu robustnú verziu:

```text
STRIP_FCS = 1
CHECK_FCS = 1
```

## Potrebná implementácia

Na stripovanie FCS potrebuje `gmii_rx_mac` 4-bajtový sliding buffer:

```text
prijaté bajty sa najprv držia v 4-byte shift registri
von sa púšťa byte až s oneskorením 4 bajty
keď frame skončí, posledné 4 bajty sa nepustia von
```

Tým sa FCS odstráni ešte v MAC vrstve.

## Testy

Pridať:

```text
tb_gmii_rx_mac_strip_fcs
tb_gmii_rx_mac_check_fcs_good
tb_gmii_rx_mac_check_fcs_bad
```

A upraviť `tb_mac_stream_tx_rx_stream` tak, aby očakával:

```text
Ethernet header + payload + padding
```

nie:

```text
Ethernet header + payload + padding + FCS
```

---

# 2. UDP checksum validácia

Odporúčam pre `eth_test_03` túto politiku:

```text
RX:
  ak UDP checksum == 0x0000, akceptuj bez kontroly
  ak UDP checksum != 0x0000, zatiaľ môžeš buď:
    A) akceptovať bez kontroly a nastaviť flag checksum_unchecked
    B) alebo dropnúť ako unsupported

TX:
  zatiaľ generuj UDP checksum = 0x0000
```

Pre IPv4 UDP je checksum `0x0000` povolený a znamená „checksum nepoužitý“. Pre jednoduchý FPGA UDP echo bring-up je to najpraktickejšie.

## Prečo zatiaľ negenerovať UDP checksum

UDP checksum vyžaduje pseudo-header:

```text
src_ip
dst_ip
zero
protocol
udp_length
UDP header
payload
```

To znamená, že checksum generátor potrebuje IP metadata aj celý payload. Pri streamovej architektúre je to komplikovanejšie než IPv4 header checksum.

Preto by som zaviedol tri fázy:

## Fáza 1 — jednoduchá

```text
RX:
  UDP checksum 0x0000 -> accept
  UDP checksum != 0x0000 -> accept, ale checksum neoverený

TX:
  UDP checksum = 0x0000
```

## Fáza 2 — prísnejšia RX validácia

```text
RX:
  UDP checksum 0x0000 -> accept
  UDP checksum != 0x0000 -> verify alebo drop
```

## Fáza 3 — plný TX checksum

```text
TX:
  vypočítať UDP checksum cez pseudo-header + UDP header + payload
```

Pre `eth_test_03` by som teraz implementoval Fázu 1.

## Návrh pre `udp_header_parser`

Výstupy:

```systemverilog
output logic [15:0] udp_checksum_o,
output logic        udp_checksum_zero_o,
output logic        udp_checksum_unchecked_o,
```

Logika:

```systemverilog
udp_checksum_zero_o      <= (udp_checksum == 16'h0000);
udp_checksum_unchecked_o <= (udp_checksum != 16'h0000);
```

A parameter:

```systemverilog
parameter bit DROP_NONZERO_CHECKSUM = 1'b0;
```

Ak `DROP_NONZERO_CHECKSUM=1`, parser nonzero checksum zahodí.

---

# 3. `rx_meta_i` handshake v `udp_echo_app`

Tu odporúčam zmeniť rozhranie na plný valid/ready handshake.

Aktuálny problém je, že `udp_echo_app` používa `rx_meta_i` priamo. To je nebezpečné, lebo metadata sa môžu zmeniť skôr, než aplikácia dokončí TX odpoveď.

## Odporúčané rozhranie

```systemverilog
input  wire logic                    rx_meta_valid_i,
output      logic                    rx_meta_ready_o,
input  wire eth_pkg::udp_packet_meta_t rx_meta_i,

output      logic                    tx_meta_valid_o,
input  wire logic                    tx_meta_ready_i,
output      eth_pkg::udp_packet_meta_t tx_meta_o,
```

## Správanie

`udp_echo_app` prijme metadata iba vtedy, keď:

```systemverilog
rx_meta_valid_i && rx_meta_ready_o
```

Vtedy ich uloží:

```systemverilog
rx_meta_q <= rx_meta_i;
payload_len_q <= rx_meta_i.payload_len;
```

A od toho momentu používa iba `rx_meta_q`.

## FSM

```text
ST_IDLE:
  čaká na rx_meta_valid_i
  rx_meta_ready_o = 1

ST_RX_PAYLOAD:
  prijíma payload do bufferu
  rx_meta_ready_o = 0

ST_TX_META:
  vystaví tx_meta_valid_o
  čaká na tx_meta_ready_i

ST_TX_PAYLOAD:
  vysiela payload späť
```

## Výstupné metadata

```systemverilog
assign tx_meta_o = '{
  src_mac:     rx_meta_q.dst_mac,
  dst_mac:     rx_meta_q.src_mac,
  src_ip:      rx_meta_q.dst_ip,
  dst_ip:      rx_meta_q.src_ip,
  src_port:    rx_meta_q.dst_port,
  dst_port:    rx_meta_q.src_port,
  payload_len: payload_len_q
};
```

## Dôležitý detail

`rx_meta_ready_o` nesmie byť stále 1. Inak môže aplikácia prijať ďalšie metadata počas toho, ako ešte spracúva predchádzajúci packet.

Správne:

```systemverilog
assign rx_meta_ready_o = (state_q == ST_IDLE);
```

A pre payload:

```systemverilog
if (s_axis_tvalid && s_axis_tready) begin
  mem[write_ptr_q] <= s_axis_tdata;
  ...
end
```

Výstup:

```systemverilog
assign m_axis_tlast = m_axis_tvalid && (read_ptr_q == payload_len_q - 1);
```

## Testy

Pridať do `tb_udp_echo_app`:

```text
T1 metadata sa zmenia po prijatí -> výstup musí použiť staré latchnuté hodnoty
T2 rx_meta_valid počas ST_RX_PAYLOAD -> rx_meta_ready_o=0
T3 tx_meta_valid drží hodnotu, kým tx_meta_ready_i=1
T4 m_axis_tready s pauzami
T5 overflow payload > MAX_PAYLOAD_BYTES
```

---

# 4. `ipv4_checksum` zapojenie

Tu treba rozlíšiť RX a TX.

## RX smer

Pre prvú verziu:

```text
ipv4_header_parser checksum môže ignorovať
```

Ale mal by mať výstup:

```systemverilog
output logic [15:0] header_checksum_o,
output logic        checksum_checked_o,
output logic        checksum_ok_o
```

V prvej fáze:

```systemverilog
checksum_checked_o = 1'b0;
checksum_ok_o      = 1'b1;
```

Neskôr vieš zapnúť kontrolu parametrom:

```systemverilog
parameter bit CHECK_IPV4_CHECKSUM = 1'b0;
```

Ak `CHECK_IPV4_CHECKSUM=1`, parser vypočíta checksum cez celý 20-bajtový header vrátane checksum fieldu a očakáva výsledok `16'hFFFF` v one's complement sum, alebo vypočíta checksum s nulovým fieldom a porovná ho s prijatým.

## TX smer

Pre TX je IPv4 checksum povinný. Ten treba generovať vždy.

Najčistejšie zapojenie:

```text
udp_ipv4_tx_builder
  - dostane tx_meta + payload_len
  - vytvorí IPv4 header
  - zavolá / použije ipv4_checksum
  - potom vyšle:
      IPv4 header 20 B
      UDP header 8 B
      UDP payload
```

Pre prvú implementáciu odporúčam kombinovaný modul:

```text
udp_ipv4_tx_builder.sv
```

namiesto samostatného `ipv4_header_builder` + `udp_header_builder`, lebo UDP echo potrebuje rýchlo poskladať jeden konkrétny formát.

## Odporúčané rozhranie `udp_ipv4_tx_builder`

```systemverilog
module udp_ipv4_tx_builder (
  input  wire logic                    clk_i,
  input  wire logic                    rst_ni,

  input  wire logic                    tx_meta_valid_i,
  output      logic                    tx_meta_ready_o,
  input  wire eth_pkg::udp_packet_meta_t tx_meta_i,

  input  wire logic [7:0]              s_axis_tdata,
  input  wire logic                    s_axis_tvalid,
  output      logic                    s_axis_tready,
  input  wire logic                    s_axis_tlast,

  output      logic [7:0]              m_axis_tdata,
  output      logic                    m_axis_tvalid,
  input  wire logic                    m_axis_tready,
  output      logic                    m_axis_tlast,

  output      logic [15:0]             ipv4_total_len_o
);
```

Výstup buildera je celý IPv4 packet:

```text
IPv4 header 20 B
UDP header 8 B
UDP payload
```

Ten ide do `gmii_tx_mac` ako Ethernet payload s:

```systemverilog
tx_ethertype_i   = 16'h0800;
tx_payload_len_i = 16'd20 + 16'd8 + tx_meta.payload_len;
```

## IPv4 checksum výpočet

Pre TX header:

```text
Version/IHL       = 0x45
DSCP/ECN          = 0x00
Total length      = 20 + 8 + payload_len
Identification    = napr. counter alebo 0x0000
Flags/fragment    = 0x4000, alebo 0x0000
TTL               = 64
Protocol          = 17
Header checksum   = vypočítať
Src IP            = tx_meta.src_ip
Dst IP            = tx_meta.dst_ip
```

Checksum field sa pri výpočte berie ako `0`.

## Testy

Pre `ipv4_checksum`:

```text
T1 známy IPv4 header -> checksum sedí
T2 header + checksum -> one's complement sum = 0xFFFF
```

Pre `udp_ipv4_tx_builder`:

```text
T1 HELLO payload:
  total_len = 33
  udp_len = 13
  protocol = 0x11
  checksum sedí
  UDP checksum = 0x0000
```

---

# Odporúčané finálne rozhodnutia

Ja by som expertovi navrhol tieto odpovede:

```text
1. FCS:
   Cieľovo stripovať a validovať v gmii_rx_mac.
   Vyššie vrstvy FCS nevidia.
   Dočasne môže gmii_rx_mac púšťať FCS, ale udp_header_parser musí zahodiť padding+FCS podľa udp_len.

2. UDP checksum:
   Pre eth_test_03 zatiaľ TX checksum = 0x0000.
   RX checksum 0x0000 akceptovať.
   Nonzero checksum zatiaľ akceptovať ako unchecked alebo dropovať parametrom.
   Plnú UDP checksum validáciu pridať neskôr.

3. rx_meta_i handshake:
   Zaviesť valid/ready.
   Metadata latchovať do rx_meta_q pri handshake.
   Počas spracovania ďalšie metadata neprijímať.
   tx_meta_valid držať, kým tx_meta_ready_i nepotvrdí prevzatie.

4. ipv4_checksum:
   TX checksum generovať vždy v udp_ipv4_tx_builder alebo ipv4_header_builder.
   RX checksum kontrolu zaviesť parametrom CHECK_IPV4_CHECKSUM, default zatiaľ 0.
```

## Najbližšie praktické poradie

```text
1. Rozhodnúť FCS politiku.
2. Implementovať udp_header_parser tak, aby podľa udp_len forwardoval iba UDP payload.
3. Opraviť udp_echo_app metadata handshake.
4. Pridať udp_ipv4_tx_builder s IPv4 checksumom.
5. Až potom full UDP echo path test.
```

Moje odporúčanie: **FCS stripovať v MAC vrstve cieľovo, ale krátkodobo navrhnúť `udp_header_parser` robustne tak, aby fungoval aj keď FCS ešte prichádza ďalej.** To ti umožní pokračovať vo vývoji L4 bez okamžitého prepisu `gmii_rx_mac`.
