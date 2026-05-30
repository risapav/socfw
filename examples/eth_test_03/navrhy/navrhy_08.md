Skontroloval som aktuálny `eth_test_03.zip`. Toto je zatiaľ najlepší stav projektu: vývoj sa už presunul z „kostry“ do reálne testovanej knižnice. Základná MAC vrstva a prvé L2/L3 bloky sú už rozumne uzavreté testami.

## 1. Celkový stav

Podľa aktuálnych logov prechádza:

```text
tb_crc32_eth                  PASS
tb_gmii_tx_mac                PASS
tb_gmii_rx_mac                PASS
tb_mac_stream_tx_rx_stream    PASS
tb_eth_header_builder         PASS
tb_eth_header_parser          PASS
tb_ipv4_header_parser         PASS
```

To znamená, že aktuálne sú overené tieto časti:

```text
CRC32 Ethernet
GMII TX MAC
GMII RX MAC
MAC loopback stream -> TX -> RX -> stream
Ethernet header builder
Ethernet header parser
IPv4 header parser
```

Toto je veľký posun. `eth_test_03` sa začína správať ako skutočná vrstvená Ethernet knižnica, nie ako monolitický experiment.

---

# 2. MAC vrstva je v dobrom stave

## `crc32_eth`

Log potvrdzuje:

```text
CRC32("123456789") = 0xCBF43926
clear_i resetuje na 0xFFFFFFFF
crc_next_o preview sedí
```

Toto je správny základ. Ethernet FCS už máš overený cez známy golden vector.

## `gmii_tx_mac`

Aktuálny `gmii_tx_mac` už prechádza 8/8 testov:

```text
72 bytov TX_EN=1
padding pre krátky payload
FCS správny
IFG = 12 cyklov
no-padding prípad
gmii_tx_er = 0
```

Kód jasne definuje kontrakt:

```text
s_axis_tvalid musí byť počas ST_PAYLOAD kontinuálne assertovaný
```

To je dôležité. Pre GMII TX je to akceptovateľný prvý návrh, ale treba to explicitne držať v dokumentácii. Ak neskôr bude upstream vedieť robiť bubliny, bude pred `gmii_tx_mac` potrebná FIFO alebo malý stream buffer.

## `gmii_rx_mac`

RX MAC tiež prechádza:

```text
prvý byte nie je SFD
tlast je na poslednom byte
0xD5 sa neobjaví na výstupe
všetkých 19 bajtov sedí
```

Toto znamená, že oprava so stavom `RX_SFD` zabrala.

Dôležitá poznámka: aktuálne `gmii_rx_mac` výstup **obsahuje FCS**. Status to správne uvádza. To je teraz akceptovateľné, ale musíš to držať v celej pipeline ako vedomé rozhodnutie.

---

# 3. MAC loopback test je veľmi dobrý míľnik

`tb_mac_stream_tx_rx_stream` prechádza:

```text
T1: HELLO payload
  RX stream má 64 B = 14 header + 5 payload + 41 padding + 4 FCS

T2: 46 B payload
  RX stream má 64 B = 14 header + 46 payload + 0 padding + 4 FCS
```

Toto potvrdzuje:

```text
gmii_tx_mac generuje korektný frame
gmii_rx_mac ho vie spätne zachytiť
header/payload/padding/FCS sú konzistentné
```

Je to presne ten test, ktorý sme chceli: `stream -> tx -> rx -> stream`.

Nasledujúci integračný MAC/L2 test by mal byť:

```text
gmii_rx_mac -> eth_header_parser -> gmii_tx_mac
```

čiže `rx -> stream -> tx` cez L2 metadata.

---

# 4. L2 vrstva je už slušne uzavretá

## `eth_header_builder`

Prechádza 3/3. Overené sú:

```text
unicast IPv4 header
broadcast IPv6-style ethertype
out-of-range byte_idx -> 0x00
```

To je dobré.

## `eth_header_parser`

Prechádza 12/12:

```text
unicast match
broadcast
MAC mismatch drop
short frame recovery
back-to-back frames
```

Doplnil si `ST_DROP`, čo je správne. To je dôležité, lebo drop frame nesmie čakať na downstream `m_axis_tready`.

### Ešte jeden detail

`eth_header_parser` nerieši EtherType filter. To nie je nutne chyba L2 parsera. Môže iba oznámiť:

```text
rx_ethertype_o
```

a vyššia vrstva rozhodne. Ale potom v integračnej pipeline musíš zabezpečiť, že IPv4 parser dostane iba `ETH_TYPE_IPV4`.

Prakticky budeš potrebovať jeden z týchto variantov:

```text
A. eth_header_parser má filter ethertype_i / accept_ipv4_i
B. medzi L2 a L3 bude ethertype demux
C. ipv4_header_parser dostane valid len keď rx_ethertype_o == 16'h0800
```

Odporúčam variant B alebo C. `eth_header_parser` by som nechal všeobecný L2 parser.

---

# 5. IPv4 parser je výrazne lepší

`tb_ipv4_header_parser` prechádza 15/15:

```text
valid UDP/local_ip
wrong dst_ip drop
TCP drop
ver/IHL=0x46 drop
short frame recovery
back-to-back frames
```

Opravy, ktoré status opisuje, sú správne:

```text
header_next_w odstránil stale validation bug
protocol offset je opravený na [87:80]
src_ip offset je opravený na [63:32]
ST_DROP konzumuje zahodený frame bez backpressure
```

Toto je už dobrý základ L3 RX parsera.

### Čo ešte chýba v IPv4 vrstve

`ipv4_checksum.sv` existuje, ale status ho označuje ako neoverený. Treba pridať:

```text
tb_ipv4_checksum
```

IPv4 parser zatiaľ podľa všetkého neoveruje IP checksum. To je v prvej fáze akceptovateľné, ale treba to jasne pomenovať:

```text
RX IPv4 checksum validation: zatiaľ nie
TX IPv4 checksum generation: bude cez ipv4_checksum
```

---

# 6. Najväčší aktuálny architektonický problém: FCS ide ďalej do L3/L4

Keďže `gmii_rx_mac` výstup obsahuje FCS, pipeline vyzerá takto:

```text
gmii_rx_mac output:
  Ethernet header + Ethernet payload + padding + FCS

eth_header_parser output:
  Ethernet payload + padding + FCS

ipv4_header_parser output:
  IPv4 payload + Ethernet padding + FCS
```

Pre UDP rámec to znamená:

```text
udp_header_parser input:
  UDP header + UDP payload + Ethernet padding + FCS
```

To je dôležité. `udp_header_parser` preto musí byť navrhnutý tak, aby:

```text
1. prečítal UDP header
2. z udp_len vypočítal payload_len = udp_len - 8
3. forwardoval presne payload_len bajtov
4. zvyšok do tlast zahodil: Ethernet padding + FCS
```

Toto je teraz najdôležitejšie pravidlo pre L4 parser.

Ak to neurobíš, `udp_echo_app` dostane payload rozšírený o padding/FCS a echo odpoveď bude zlá.

---

# 7. `udp_header_parser` je teraz hlavný chýbajúci modul

Status to správne označuje. Navrhoval by som rozhranie takto:

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

FSM:

```text
ST_HEADER
ST_PAYLOAD
ST_DROP
ST_FLUSH
```

Presnejšie:

```text
ST_HEADER:
  zbiera 8 bajtov UDP headera

ST_PAYLOAD:
  forwarduje presne payload_len bajtov

ST_FLUSH:
  konzumuje zvyšok do tlast — padding + FCS

ST_DROP:
  konzumuje celý frame do tlast bez výstupu
```

Validácie:

```text
udp_len >= 8
dst_port == local_port_i alebo promiscuous_i
payload_len = udp_len - 8
```

`m_axis_tlast` musí byť generovaný na poslednom UDP payload bajte, nie na Ethernet `s_axis_tlast`.

To je veľmi dôležité.

---

# 8. `udp_echo_app` treba ešte opraviť

Aktuálny `udp_echo_app.sv` má stále problém, ktorý status správne uvádza:

```text
rx_meta_i nie je latchovaný
```

V aktuálnom kóde sa stále používa `rx_meta_i` počas TX fázy. To je rizikové. Treba pridať:

```systemverilog
eth_pkg::udp_packet_meta_t rx_meta_q;
logic [15:0] payload_len_q;
```

Pri prijatí metadata:

```systemverilog
if (rx_meta_valid_i) begin
  rx_meta_q     <= rx_meta_i;
  payload_len_q <= rx_meta_i.payload_len;
end
```

Potom výstup:

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

Tiež treba opraviť handshake:

```systemverilog
if (s_axis_tvalid && s_axis_tready) begin
  mem[write_ptr] <= s_axis_tdata;
end
```

a:

```systemverilog
assign m_axis_tlast = m_axis_tvalid && (read_ptr == payload_len_q - 1);
```

Pridať overflow:

```systemverilog
if ((write_ptr == MAX_PAYLOAD_BYTES-1) && !s_axis_tlast) begin
  overflow_q <= 1'b1;
end
```

---

# 9. Top-level zatiaľ nerieš

`ethernet_test_03_top.sv` je stále len čiastočný top. Vidím tam tieto konkrétne problémy:

```systemverilog
.m_axis_tuser(1'b0)
```

To je zle, pretože `m_axis_tuser` je výstup z `gmii_rx_mac`. Nemá byť pripojený na konštantu. Potrebuješ signál:

```systemverilog
logic rx_axis_tuser;
```

a potom:

```systemverilog
.m_axis_tuser(rx_axis_tuser)
```

Ďalej top inštancuje:

```systemverilog
eth_debug_leds u_leds
```

ale v ZIP-e tento modul stále nevidím.

A TX vetva zatiaľ nie je zapojená. Preto by som top teraz ešte nekompiloval ako cieľový systém. Najskôr dokonči L4 a buildery.

---

# 10. Chýbajú TX buildery

Aby si postavil plný UDP echo path, nestačí mať RX parsery a echo app. Potrebuješ aj TX buildery:

```text
udp_header_builder
ipv4_header_builder
```

Následná TX skladba má byť:

```text
udp_echo_app payload stream
  -> udp_header_builder pridá UDP header
  -> ipv4_header_builder pridá IPv4 header
  -> gmii_tx_mac pridá Ethernet header, padding, FCS, IFG
```

Alebo ako jednoduchšia prvá verzia:

```text
udp_ipv4_tx_builder
  vstup: tx_meta + payload stream
  výstup: celý IPv4 packet stream pre gmii_tx_mac
```

Pre rýchly pokrok by som odporúčal najprv jeden modul:

```text
udp_ipv4_tx_builder.sv
```

ktorý vytvorí:

```text
IPv4 header 20 B
UDP header 8 B
UDP payload
```

a jeho výstup pôjde ako `s_axis` payload do `gmii_tx_mac` s:

```text
tx_ethertype_i = 16'h0800
tx_payload_len_i = 20 + 8 + payload_len
```

Neskôr ho môžeš rozdeliť na `ipv4_header_builder` a `udp_header_builder`.

---

# 11. Sim/Makefile je už lepší

Pozitíva:

```text
gmii_rx cieľ už kompiluje gmii_rx_mac.sv
mac_stream test je pridaný
eth_header_builder/parser testy sú pridané
ipv4_header_parser test je pridaný
regression: clean all
```

To je správne.

Čo ešte pridať:

```text
tb_ipv4_checksum
tb_udp_header_parser
tb_udp_echo_app
tb_l2_l3_udp_rx_path
tb_udp_ipv4_tx_builder
tb_udp_echo_full_path
```

---

# 12. Odporúčaný ďalší postup

Teraz by som išiel takto:

## Krok 1 — uzavrieť `ipv4_checksum`

Pridať:

```text
sim/l3/tb_ipv4_checksum.sv
```

Testy:

```text
valid 20-byte IPv4 header -> očakávaný checksum
header s checksumom vloženým -> one's complement sum = 0xFFFF
zmena src/dst IP zmení checksum
```

## Krok 2 — vytvoriť `udp_header_parser`

Toto je najbližší hlavný blok.

Testy:

```text
T1 valid UDP dst_port=8080, payload HELLO, potom padding+FCS -> forwarduje iba HELLO
T2 wrong dst_port -> drop, 0 bytes
T3 udp_len < 8 -> drop
T4 short frame počas headera -> reset, next frame OK
T5 back-to-back UDP payloady
```

Najdôležitejší test je T1: parser musí zahodiť padding+FCS podľa `udp_len`.

## Krok 3 — opraviť a otestovať `udp_echo_app`

Test:

```text
metadata + HELLO -> metadata otočené + HELLO
random m_axis_tready
rx_meta_i sa po prijatí zmení -> výstup musí stále používať latchnuté hodnoty
overflow test
```

## Krok 4 — RX integračný test po L4

Pridať:

```text
tb_l2_l3_l4_rx_path
```

Schéma:

```text
gmii_tx_mac -> gmii_rx_mac -> eth_header_parser -> ipv4_header_parser -> udp_header_parser
```

Vstup: UDP HELLO frame.

Očakávanie:

```text
udp_header_parser output = iba HELLO
nie padding
nie FCS
metadata = src/dst port + IP + MAC správne poskladané
```

## Krok 5 — TX builder

Pridať `udp_ipv4_tx_builder` alebo dvojicu:

```text
udp_header_builder
ipv4_header_builder
```

Na začiatok odporúčam jeden kombinovaný modul:

```text
udp_ipv4_tx_builder
```

Test:

```text
tx_meta + HELLO -> IPv4 header + UDP header + HELLO
IP checksum sedí
UDP length sedí
```

## Krok 6 — full UDP echo path

Až potom:

```text
GMII RX UDP request
 -> RX MAC
 -> L2
 -> L3
 -> L4
 -> echo app
 -> TX builder
 -> GMII TX MAC
 -> GMII TX frame
```

Scoreboard musí porovnať celý TX frame byte-by-byte vrátane:

```text
preamble/SFD
Ethernet header
IPv4 header
UDP header
payload
padding
FCS
```

---

# 13. Krátky verdikt

Aktuálny stav by som zhrnul takto:

```text
MAC vrstva: PASS
L2 vrstva: PASS
L3 RX parser: PASS
L3 checksum: čaká test
L4 UDP parser: chýba
Echo app: rozpracovaná, treba opraviť metadata/handshake
TX IPv4/UDP builder: chýba
Top: zatiaľ neuzatvárať
```

Najdôležitejšie rozhodnutie teraz: keďže `gmii_rx_mac` zatiaľ posiela FCS ďalej, **`udp_header_parser` musí forwardovať iba UDP payload podľa `udp_len` a zvyšok rámca až po `tlast` zahodiť**. Toto je kľúčové, aby sa padding a FCS nedostali do aplikácie ani do echo odpovede.
