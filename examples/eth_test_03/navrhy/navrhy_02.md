Analyzoval som aktuálny `eth_test_03.zip`. Stav je lepší než predošlá kostra, ale projekt ešte nie je pripravený na full-path UDP echo simuláciu. Najprv treba uzavrieť základné knižničné moduly po vrstvách.

## 1. Aktuálny stav kódu

V ZIP-e sú tieto hlavné moduly:

```text
rtl/eth/eth_pkg.sv
rtl/eth/ethernet_test_03_top.sv
rtl/eth/l2/eth_header_builder.sv
rtl/eth/l2/eth_header_parser.sv
rtl/eth/l3/ipv4_checksum.sv
rtl/eth/l3/ipv4_header_parser.sv
rtl/eth/l4/udp_echo_app.sv
rtl/eth/mac/crc32_eth.sv
rtl/eth/mac/gmii_rx_mac.sv
rtl/eth/mac/gmii_tx_mac.sv
rtl/eth/util/mdio_master.sv
sim/tb_udp_echo_full_path.sv
```

Pozitívne zmeny:

```text
+ eth_pkg.sv je použiteľný základ
+ crc32_eth.sv už používa LSB-first 0xEDB88320
+ eth_header_builder.sv je dobrý a jednoduchý
+ eth_header_parser.sv už má vyplnené všetky MAC/EtherType bajty
+ ipv4_checksum.sv je doplnený
+ udp_echo_app.sv už má základnú FSM
+ gmii_tx_mac.sv už má FSM stavy pre preambulu/header/payload/padding/FCS/IFG
```

Ale stále sú tam zásadné blokery.

---

# 2. Projekt ako celok ešte nie je kompilovateľný

`ethernet_test_03_top.sv` inštancuje:

```systemverilog
eth_debug_leds u_leds (...);
```

ale v ZIP-e nie je súbor `eth_debug_leds.sv`.

Top tiež zatiaľ nemá zapojenú TX cestu. Sú tam len RX MAC, Ethernet parser, IPv4 parser a komentár:

```systemverilog
// 4. UDP Echo App (Aplikácia) - Tu by bolo napojenie na parsery
// ... implementácia UDP parsera a Echo App ...
```

Výstupy:

```systemverilog
eth_txd_o
eth_txen_o
eth_txer_o
```

nie sú reálne riadené.

Tiež chýba:

```text
udp_header_parser.sv
udp_header_builder.sv
ipv4_header_builder.sv
eth_debug_leds.sv
```

Preto by som teraz nerobil full-path top test ako hlavný test. Najprv treba modulové testy.

---

# 3. Kritické funkčné problémy v moduloch

## 3.1 `gmii_rx_mac.sv` má chybu pri preambule

Aktuálny RX MAC po detekcii `D5` prejde do `RX_DATA`, ale na výstup pravdepodobne vypustí aj samotné `D5`.

Dôvod: `rxd_q` drží predchádzajúci bajt a `state_q` sa prepne na `RX_DATA` až po hrane. Pri prvom cykle `RX_DATA` teda môže byť `m_axis_tdata = 8'hD5`.

To je zlé. Výstupný stream z `gmii_rx_mac` má začínať prvým bajtom Ethernet rámca:

```text
destination MAC byte 0
```

nie SFD.

Toto musí zachytiť test:

```text
input:  55 55 55 55 55 55 55 D5 DE AD BE EF ...
output: DE AD BE EF ...
```

Ak výstup začne `D5`, test musí spadnúť.

## 3.2 `gmii_rx_mac` nerešpektuje `m_axis_tready`

Výstup je odvodený priamo od GMII:

```systemverilog
assign m_axis_tvalid = (state_q == RX_DATA && dv_q);
```

Ak downstream nie je ready, dáta sa stratia. GMII RX nemá spätný tlak, takže sú len dve možnosti:

```text
A. Dokumentovať: m_axis_tready musí byť stále 1.
B. Vložiť FIFO za gmii_rx_mac.
```

Pre knižnicu odporúčam B:

```text
gmii_rx_mac -> stream_fifo -> parsre
```

Ale prvé testy môžu predpokladať `m_axis_tready=1`.

## 3.3 `gmii_tx_mac.sv` má zlý handshake v payload stave

V `ST_PAYLOAD` robíš:

```systemverilog
gmii_txd_o = s_axis_tdata;
s_axis_tready = 1'b1;
if (s_axis_tvalid && s_axis_tlast) ...
```

Ale `gmii_tx_en_o` je aktívny počas celého `ST_PAYLOAD`, aj keď `s_axis_tvalid=0`. V takom prípade TX MAC vysiela neplatný `s_axis_tdata`.

Buď musí byť pravidlo:

```text
Po vstupe do ST_PAYLOAD musí byť s_axis_tvalid stále 1 bez bublín.
```

alebo musí TX MAC čakať na valid a držať `TXEN=0`/neposúvať FSM. Pre knižničný modul odporúčam robustnejšie riešenie: v payload stave vysielať bajt iba pri handshake:

```systemverilog
payload_fire = s_axis_tvalid && s_axis_tready;
```

a čítače posúvať len pri `payload_fire`.

Inak test s jednou medzerou vo valid signáli odhalí chybu.

## 3.4 `gmii_tx_mac` má problém s počítaním `byte_cnt`

Používa jeden `byte_cnt` pre header, payload, padding, FCS a IFG. Pri prechode medzi stavmi sa čítače nulujú:

```systemverilog
if (state_q != state_d) begin
  preamble_cnt <= '0;
  byte_cnt     <= '0;
  header_idx   <= '0;
end
```

Potom v `ST_PAYLOAD` rozhoduješ:

```systemverilog
if (s_axis_tvalid && s_axis_tlast)
  state_d = (byte_cnt < MIN_FRAME_NO_FCS-1) ? ST_PADDING : ST_FCS;
```

Lenže `byte_cnt` v payload stave neobsahuje celkový počet bajtov Ethernet frame bez FCS. Po prechode z headera do payloadu sa vynuloval. Teda padding výpočet bude nesprávny.

Správne potrebuješ samostatný počítač:

```text
frame_byte_cnt = počet bajtov zahrnutých do CRC od Ethernet headera po payload/padding
payload_byte_cnt = počet payload bajtov
fcs_byte_cnt
ifg_cnt
```

Padding sa má rozhodovať podľa:

```text
frame_byte_cnt < MIN_FRAME_NO_FCS
```

nie podľa payload-only `byte_cnt`.

## 3.5 `ipv4_header_parser.sv` používa starý `header_reg` pri validácii

V stave, keď príde 20. bajt:

```systemverilog
header_reg <= {header_reg[151:0], s_axis_tdata};
if (byte_cnt == 5'd19) begin
  hdr_valid_int <= (header_reg[159:152] == 8'h45) && (header_reg[31:0] == local_ip_i);
end
```

`hdr_valid_int` používa starú hodnotu `header_reg`, teda bez aktuálneho `s_axis_tdata`. Validácia cieľovej IP môže byť chybná.

Oprava:

```systemverilog
logic [159:0] header_next_w;
assign header_next_w = {header_reg[151:0], s_axis_tdata};
```

a validovať:

```systemverilog
hdr_valid_int <= (header_next_w[159:152] == 8'h45) &&
                 (header_next_w[79:72]   == eth_pkg::IPV4_PROTO_UDP) &&
                 (header_next_w[31:0]    == local_ip_i);
```

Tiež treba kontrolovať `protocol == UDP`.

## 3.6 `eth_header_parser.sv` validuje až po headeri, ale nerobí `EtherType` filter

Parser vyberie MAC/EtherType, ale ďalej pustí payload ak sedí MAC. Nezahodí napríklad ARP alebo IPv6. To nemusí byť chyba L2 parsera, ale potom L3 parser musí mať jasné `drop`.

Pre testy treba mať prípady:

```text
dst MAC mismatch -> drop
broadcast accepted -> pass
ethertype ARP -> nemá ísť do IPv4 parsera
```

## 3.7 `udp_echo_app.sv` už má FSM, ale stále je slabý

Lepšie než predtým, ale ešte sú problémy:

```systemverilog
if (s_axis_tvalid) begin
  mem[write_ptr] <= s_axis_tdata;
  write_ptr <= write_ptr + 1'b1;
```

Ignoruje sa `s_axis_tready`, hoci výstup ho poskytuje. Malo by byť:

```systemverilog
if (s_axis_tvalid && s_axis_tready) begin
```

Ďalej:

```systemverilog
m_axis_tlast = (read_ptr == rx_meta_i.payload_len - 1);
```

`tlast` je aktívny aj keď `m_axis_tvalid=0`, ak je `read_ptr` na poslednom bajte. Lepšie:

```systemverilog
assign m_axis_tlast = m_axis_tvalid && (read_ptr == payload_len_q - 1);
```

A veľmi dôležité: `rx_meta_i` sa nepamätá do registra. Ak sa po prijatí payloadu zmení, TX metadata aj `payload_len` sa zmenia počas vysielania. Treba latcheovať:

```systemverilog
eth_pkg::udp_packet_meta_t rx_meta_q;
logic [15:0] payload_len_q;
```

pri prijatí `rx_meta_valid_i`.

---

# 4. Navrhovaný komplex testbenchov

Navrhol by som testy po vrstvách. Nie jeden veľký test, ale regresiu, ktorá postupne uzatvára knižnicu.

## 4.1 Štruktúra `sim/`

```text
sim/
  Makefile
  common/
    tb_eth_common_pkg.sv
    tb_scoreboard_pkg.sv
  unit/
    tb_crc32_eth.sv
    tb_eth_header_builder.sv
    tb_eth_header_parser.sv
    tb_ipv4_checksum.sv
    tb_ipv4_header_parser.sv
    tb_udp_echo_app.sv
  mac/
    tb_gmii_tx_mac_min_frame.sv
    tb_gmii_tx_mac_no_padding.sv
    tb_gmii_tx_mac_valid_gap.sv
    tb_gmii_tx_mac_ifg.sv
    tb_gmii_rx_mac_with_preamble.sv
    tb_gmii_rx_mac_no_preamble.sv
    tb_gmii_rx_mac_rxer_abort.sv
  integration/
    tb_l2_l3_rx_path.sv
    tb_udp_echo_app_path.sv
    tb_eth_test_03_udp_full_path.sv
```

---

# 5. Spoločný test package

Najprv si sprav `sim/common/tb_eth_common_pkg.sv`.

Mal by obsahovať:

```systemverilog
package tb_eth_common_pkg;

  typedef byte unsigned byte_q_t[$];

  localparam logic [47:0] FPGA_MAC = 48'h000A3501FEC0;
  localparam logic [47:0] PC_MAC   = 48'hDEADBEEF1234;

  localparam logic [31:0] FPGA_IP  = 32'hC0A81432; // 192.168.20.50
  localparam logic [31:0] PC_IP    = 32'hC0A81464; // 192.168.20.100

  localparam logic [15:0] UDP_FPGA_PORT = 16'd8080;
  localparam logic [15:0] UDP_PC_PORT   = 16'd4567;

  function automatic logic [15:0] ipv4_checksum_bytes(input byte unsigned hdr[$]);
    logic [31:0] sum;
    logic [15:0] word;
    begin
      sum = 0;
      for (int i = 0; i < hdr.size(); i += 2) begin
        word = {hdr[i], hdr[i+1]};
        sum += word;
      end
      while (sum[31:16] != 0)
        sum = (sum[15:0] + sum[31:16]);
      return ~sum[15:0];
    end
  endfunction

  function automatic logic [31:0] crc32_eth_bytes(input byte unsigned data[$]);
    logic [31:0] crc;
    logic        fb;
    begin
      crc = 32'hFFFF_FFFF;
      foreach (data[i]) begin
        for (int b = 0; b < 8; b++) begin
          fb = crc[0] ^ data[i][b];
          crc = crc >> 1;
          if (fb) crc ^= 32'hEDB8_8320;
        end
      end
      return ~crc;
    end
  endfunction

endpackage
```

Tento package bude generovať golden hodnoty. Nehardcoduj FCS ručne v každom teste.

---

# 6. Unit testy

## 6.1 `tb_crc32_eth.sv`

Testy:

```text
T1 reset -> crc_state = FFFF_FFFF
T2 "123456789" -> fcs = CBF43926
T3 Ethernet frame bez FCS -> dopočítaj FCS, potom frame+FCS residue = DEBB20E3
T4 clear_i počas výpočtu resetne CRC
T5 en_i=0 drží stav
```

Toto je P0. Bez neho netestuj `gmii_tx_mac`.

---

## 6.2 `tb_eth_header_builder.sv`

Vstup:

```text
dst = DE:AD:BE:EF:12:34
src = 00:0A:35:01:FE:C0
ethertype = 0800
```

Očakávané bajty:

```text
DE AD BE EF 12 34 00 0A 35 01 FE C0 08 00
```

Testuj `byte_idx_i = 0..13`.

---

## 6.3 `tb_eth_header_parser.sv`

Prípady:

```text
T1 unicast na LOCAL_MAC -> payload prejde
T2 broadcast -> prejde, ak accept_broadcast_i=1
T3 wrong MAC -> payload neprejde, drop_o=1
T4 dva frame za sebou -> parser sa musí vrátiť do ST_HEADER
T5 backpressure počas headera
T6 backpressure počas payloadu
```

Pozor: ak `s_axis_tready = m_axis_tready`, parser sa pri backpressure počas headera zastaví. To je formálne OK, ak upstream je stream FIFO, ale test to musí vedome overiť.

---

## 6.4 `tb_ipv4_checksum.sv`

Testuj známy header.

Napríklad IPv4 header:

```text
45 00 00 21 12 34 40 00 80 11 00 00 C0 A8 14 64 C0 A8 14 32
```

Test vypočíta checksum v TB funkcii a porovná s DUT.

Tiež testuj:

```text
T1 checksum field nulový
T2 header so zmeneným src/dst IP
T3 edge case carry folding
```

---

## 6.5 `tb_ipv4_header_parser.sv`

Vstup: IPv4 header + payload.

Testy:

```text
T1 valid IPv4 UDP na LOCAL_IP -> payload prejde
T2 dst IP mismatch -> drop
T3 version/IHL != 0x45 -> drop
T4 protocol != UDP -> drop
T5 dva IP pakety za sebou
T6 s_axis_tlast počas headera -> frame_error/drop
```

Tento test odhalí aktuálnu chybu s použitím starého `header_reg` pri validácii.

---

## 6.6 `tb_udp_echo_app.sv`

Toto je samostatný test aplikácie bez Ethernetu.

Vstup:

```text
rx_meta:
  src_mac = PC
  dst_mac = FPGA
  src_ip = PC_IP
  dst_ip = FPGA_IP
  src_port = 4567
  dst_port = 8080
  payload_len = 5

payload:
  "HELLO"
```

Očakávané:

```text
tx_meta:
  src_mac = FPGA
  dst_mac = PC
  src_ip = FPGA_IP
  dst_ip = PC_IP
  src_port = 8080
  dst_port = 4567
  payload_len = 5

tx payload:
  "HELLO"
```

Testy:

```text
T1 HELLO echo
T2 payload_len=1
T3 payload_len=18
T4 payload_len=0, ak chceš podporovať empty UDP payload
T5 m_axis_tready s náhodnými pauzami
T6 s_axis_tvalid s pauzami
T7 overflow > MAX_PAYLOAD_BYTES -> error/drop
```

Aktuálny `udp_echo_app` by zlyhal minimálne pri valid-gap/backpressure a pri zmene `rx_meta_i`, ak nie je stabilné.

---

# 7. GMII MAC testy

## 7.1 `tb_gmii_tx_mac_min_frame.sv`

Vstup do `gmii_tx_mac`:

```text
Ethernet payload = IPv4/UDP HELLO, 33 bajtov
payload_len_i = 33
```

Očakávaný GMII výstup:

```text
7x 55
D5
Ethernet header 14 B
payload 33 B
padding 13 B
FCS 4 B
IFG >= 12 cyklov TXEN=0
```

Celková dĺžka s preambulou a FCS:

```text
8 + 14 + 33 + 13 + 4 = 72 bajtov
```

Kontroly:

```text
- presná preambula
- presný SFD
- presný Ethernet header
- padding 13x 00
- FCS byte order little-endian
- CRC residue DEBB20E3
- IFG >= 12
```

Tento test pravdepodobne teraz odhalí problém s `byte_cnt`/paddingom v `gmii_tx_mac`.

---

## 7.2 `tb_gmii_tx_mac_no_padding.sv`

Payload dlhý napríklad 60 bajtov.

```text
14 + 60 = 74 > 60
padding = 0
```

Kontrola:

```text
žiadne extra 00 pred FCS, iba dáta payloadu
```

---

## 7.3 `tb_gmii_tx_mac_valid_gap.sv`

Pošli payload s medzerou:

```text
valid: 1 1 0 1 1 ...
```

Očakávané správanie musíš rozhodnúť:

```text
Variant A: TX MAC nepodporuje valid gap -> test očakáva assertion/fail v simulácii.
Variant B: TX MAC čaká na valid -> TXEN počas medzery nesmie vysielať neplatný bajt.
```

Pre knižnicu odporúčam Variant B alebo použiť vstupnú FIFO, ktorá garantuje plynulý stream.

---

## 7.4 `tb_gmii_tx_mac_ifg.sv`

Pošli dva rámce za sebou.

Kontrola:

```text
medzi posledným FCS bajtom frame 1 a preambulou frame 2 je TXEN=0 aspoň 12 cyklov
```

---

## 7.5 `tb_gmii_rx_mac_with_preamble.sv`

GMII vstup:

```text
55 55 55 55 55 55 55 D5 DE AD BE EF 12 34 ...
```

Očakávaný AXI stream:

```text
DE AD BE EF 12 34 ...
```

Kontroly:

```text
- SFD D5 nesmie byť vo výstupe
- prvý výstupný bajt je destination MAC[47:40]
- tlast je na poslednom bajte frame
- frame_done_o pulzne
```

Tento test je P0, lebo aktuálny `gmii_rx_mac` pravdepodobne vypustí `D5`.

---

## 7.6 `tb_gmii_rx_mac_no_preamble.sv`

Pri `EXPECT_PREAMBLE=0` vstup začína rovno:

```text
DE AD BE EF 12 34 ...
```

Očakávanie:

```text
prvý výstupný bajt = DE
```

---

## 7.7 `tb_gmii_rx_mac_rxer_abort.sv`

Počas rámca daj `gmii_rx_er_i=1`.

Očakávanie:

```text
m_axis_tuser alebo frame_error_o = 1
frame sa zahodí alebo označí ako chybný
```

Aktuálne `m_axis_tuser = gmii_rx_er_i`, ale tým zachytíš len aktuálny cyklus. Lepšie je latchnúť error do konca frame.

---

# 8. Integračné testy

## 8.1 `tb_l2_l3_rx_path.sv`

Reťazec:

```text
gmii_rx_mac -> eth_header_parser -> ipv4_header_parser
```

Pošli Ethernet+IPv4+payload.

Kontroluj:

```text
src_mac/dst_mac/ethertype
src_ip/dst_ip/protocol
payload ide ďalej presne od prvého IP payload bajtu
```

Prípady:

```text
valid UDP
wrong MAC
wrong IP
non-IPv4 EtherType
no-preamble
with-preamble
```

---

## 8.2 `tb_udp_echo_app_path.sv`

Bez GMII, len:

```text
metadata + payload -> udp_echo_app -> reversed metadata + payload
```

Použi random ready/valid pauzy.

---

## 8.3 `tb_eth_test_03_udp_full_path.sv`

Až keď prejdú všetky vyššie testy.

Cieľ:

```text
GMII RX frame -> celý stack -> GMII TX echo frame
```

Vstupný UDP request:

```text
PC MAC:   DE:AD:BE:EF:12:34
FPGA MAC: 00:0A:35:01:FE:C0
PC IP:    192.168.20.100
FPGA IP:  192.168.20.50
PC port:  4567
FPGA port:8080
payload:  HELLO
```

Očakávaný TX:

```text
dst MAC = PC MAC
src MAC = FPGA MAC
src IP  = FPGA IP
dst IP  = PC IP
src UDP = 8080
dst UDP = 4567
payload = HELLO
padding = 13x00
valid FCS
IFG >= 12
```

Tento test musí robiť byte-by-byte porovnanie celého TX frame.

---

# 9. Navrhovaný `sim/Makefile`

Princíp:

```makefile
RTL = ../rtl/eth

COMMON = \
  $(RTL)/eth_pkg.sv

MAC = \
  $(RTL)/mac/crc32_eth.sv \
  $(RTL)/l2/eth_header_builder.sv \
  $(RTL)/mac/gmii_tx_mac.sv \
  $(RTL)/mac/gmii_rx_mac.sv

L2 = \
  $(RTL)/l2/eth_header_parser.sv

L3 = \
  $(RTL)/l3/ipv4_checksum.sv \
  $(RTL)/l3/ipv4_header_parser.sv

L4 = \
  $(RTL)/l4/udp_echo_app.sv

UNIT_TESTS = \
  tb_crc32_eth \
  tb_eth_header_builder \
  tb_eth_header_parser \
  tb_ipv4_checksum \
  tb_ipv4_header_parser \
  tb_udp_echo_app

MAC_TESTS = \
  tb_gmii_tx_mac_min_frame \
  tb_gmii_tx_mac_no_padding \
  tb_gmii_tx_mac_valid_gap \
  tb_gmii_tx_mac_ifg \
  tb_gmii_rx_mac_with_preamble \
  tb_gmii_rx_mac_no_preamble \
  tb_gmii_rx_mac_rxer_abort

INTEGRATION_TESTS = \
  tb_l2_l3_rx_path \
  tb_udp_echo_app_path \
  tb_eth_test_03_udp_full_path
```

Každý test musí zapisovať log do `sim/logs`.

Regresia:

```makefile
regression: clean unit mac integration
	@grep -R "FAIL\|Fatal\|Error" logs && exit 1 || echo "PASS"
```

---

# 10. Priorita testovania

Nepreskakuj poradie. Pre aktuálny stav odporúčam:

## P0

```text
tb_crc32_eth
tb_eth_header_builder
tb_gmii_tx_mac_min_frame
tb_gmii_rx_mac_with_preamble
tb_gmii_rx_mac_no_preamble
```

Tieto testy odhalia najkritickejšie chyby.

## P1

```text
tb_gmii_tx_mac_ifg
tb_gmii_tx_mac_valid_gap
tb_eth_header_parser
tb_ipv4_checksum
tb_ipv4_header_parser
tb_udp_echo_app
```

## P2

```text
tb_l2_l3_rx_path
tb_udp_echo_app_path
tb_eth_test_03_udp_full_path
```

---

# 11. Čo by som opravil ešte pred písaním full-path TB

Pred full-path testom by som opravil tieto RTL veci:

```text
1. gmii_rx_mac nesmie vypúšťať D5 ako prvý dátový bajt.
2. gmii_tx_mac musí mať samostatný frame_byte_cnt/payload_cnt/fcs_cnt/ifg_cnt.
3. gmii_tx_mac musí správne riešiť s_axis_tvalid gap alebo jasne vyžadovať gapless stream.
4. ipv4_header_parser musí validovať header_next_w, nie starý header_reg.
5. udp_echo_app musí latcheovať rx_meta_i a payload_len.
6. udp_echo_app musí používať s_axis_tvalid && s_axis_tready.
7. top musí prestať inštancovať chýbajúci eth_debug_leds alebo ho treba doplniť.
8. doplniť udp_header_parser/udp_header_builder/ipv4_header_builder, ak chceš full UDP echo.
```

---

## Záver

`eth_test_03` je už dobrý základ knižnice, ale zatiaľ má byť testovaný **zdola nahor**, nie ako celý UDP echo systém.

Najdôležitejšia testovacia stratégia:

```text
1. CRC musí byť dokázané golden vektormi.
2. GMII TX musí vedieť vyrobiť presný Ethernet frame.
3. GMII RX musí správne stripnúť preambulu/SFD a vyrobiť tlast.
4. L2/L3/L4 parsery musia samostatne filtrovať a púšťať payload.
5. Echo app musí samostatne otočiť metadata a payload.
6. Až potom full-path GMII UDP echo.
```

Ak toto dodržíš, z `eth_test_03` vznikne reálne použiteľná Ethernet knižnica, nie ďalší monolitický test, ktorý sa ťažko ladí na FPGA.
