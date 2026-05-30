Skontroloval som aktuálny `eth_test_03.zip`. Stav je lepší než predchádzajúca kostra, ale stále to **nie je kompilovateľný ani funkčný Ethernet stack**. Je to užitočný návrh API a vrstiev, ale viaceré moduly sú stále iba čiastočne doplnené.

## Hlavný verdikt

Aktuálne najväčšie blokery sú:

```text
1. ethernet_test_03_top.sv stále obsahuje neplatné `...`
2. udp_header_parser.sv úplne chýba
3. gmii_tx_mac.sv nemá implementované čítače ani výstupný multiplex
4. gmii_rx_mac.sv nevie korektne generovať tlast/frame_done
5. crc32_eth.sv má pravdepodobne nesprávnu bitovú orientáciu pre Ethernet CRC
6. eth_header_parser.sv sa zasekne na byte_cnt=0
7. udp_echo_app.sv nemá FSM a stále drží m_axis_tvalid=1
8. tb_udp_echo_full_path.sv zatiaľ neposiela žiadny packet a nekontroluje nič
```

Čiže: **adresárová a modulová architektúra je dobrý smer, ale implementačne si stále vo fáze skeleton/prototyp**.

---

# 1. `eth_pkg.sv`

Tento súbor je v poriadku ako základ.

Obsahuje dobré definície:

```systemverilog
ETH_TYPE_IPV4 = 16'h0800
ETH_TYPE_ARP  = 16'h0806
IPV4_PROTO_UDP = 8'h11
ETH_HEADER_BYTES = 14
ETH_MIN_NO_FCS = 60
GMII_IFG_BYTES = 12
```

Typy sú tiež vhodné:

```systemverilog
eth_hdr_t
ipv4_meta_t
udp_meta_t
udp_packet_meta_t
```

Doplnil by som ešte:

```systemverilog
localparam logic [47:0] ETH_BROADCAST_MAC = 48'hFFFF_FFFFFFFF;
localparam int ETH_PREAMBLE_BYTES = 7;
localparam int ETH_SFD_BYTES      = 1;
localparam int ETH_MIN_WITH_FCS   = 64;
localparam int UDP_MIN_LEN        = 8;
```

Toto je dobrý základ knižnice.

---

# 2. `crc32_eth.sv`

Toto je teraz kritický problém.

Aktuálna funkcia používa MSB-first výpočet:

```systemverilog
if (c[31] ^ data[i])
  c = (c << 1) ^ 32'h04C11DB7;
else
  c = c << 1;
```

Pre Ethernet GMII bajtový stream sa bežne používa LSB-first výpočet s reverzným polynómom:

```systemverilog
32'hEDB88320
```

Odporúčam zmeniť funkciu na:

```systemverilog
function automatic logic [31:0] next_crc32_eth_byte (
  input logic [31:0] crc_i,
  input logic [7:0]  data_i
);
  logic [31:0] c;
  logic        fb;
  begin
    c = crc_i;

    for (int i = 0; i < 8; i++) begin
      fb = c[0] ^ data_i[i];
      c  = c >> 1;
      if (fb)
        c ^= 32'hEDB8_8320;
    end

    return c;
  end
endfunction
```

A povinne pridať test:

```text
"123456789" -> FCS 32'hCBF43926
```

Bez správneho CRC nemá zmysel ladiť `gmii_tx_mac`.

---

# 3. `gmii_tx_mac.sv`

Modul má správnu predstavu FSM:

```systemverilog
ST_IDLE
ST_PREAMBLE
ST_SFD
ST_ETH_HEADER
ST_PAYLOAD
ST_PADDING
ST_FCS
ST_IFG
```

Ale implementácia je stále nehotová.

## Problém 1: `gmii_txd_o` je priamo riadené header builderom

Máš:

```systemverilog
eth_header_builder i_hdr_builder (
  ...
  .byte_o(gmii_txd_o)
);
```

To je zlé. `eth_header_builder` má dávať iba interný bajt, nie priamo výstup na GMII.

Správne:

```systemverilog
logic [7:0] eth_hdr_byte_w;

eth_header_builder i_hdr_builder (
  .dst_mac_i   (tx_dst_mac_i),
  .src_mac_i   (tx_src_mac_i),
  .ethertype_i (tx_ethertype_i),
  .byte_idx_i  (header_idx_q),
  .byte_o      (eth_hdr_byte_w)
);
```

A potom výstupný mux:

```systemverilog
case (state_q)
  ST_PREAMBLE:   gmii_txd_d = 8'h55;
  ST_SFD:        gmii_txd_d = 8'hD5;
  ST_ETH_HEADER: gmii_txd_d = eth_hdr_byte_w;
  ST_PAYLOAD:    gmii_txd_d = s_axis_tdata;
  ST_PADDING:    gmii_txd_d = 8'h00;
  ST_FCS:        gmii_txd_d = fcs_byte_w;
  default:       gmii_txd_d = 8'h00;
endcase
```

## Problém 2: čítače nie sú implementované

Sú deklarované:

```systemverilog
preamble_cnt
byte_cnt
header_idx
```

ale nikde sa reálne neresetujú ani neinkrementujú. FSM teda nemá ako fungovať.

## Problém 3: CRC vstup je zlý

Máš:

```systemverilog
.data_i(fcs_byte)
```

Do CRC nemá ísť `fcs_byte`. Do CRC má ísť práve vysielaný bajt počas:

```text
ST_ETH_HEADER
ST_PAYLOAD
ST_PADDING
```

Nie počas:

```text
ST_PREAMBLE
ST_SFD
ST_FCS
ST_IFG
```

## Problém 4: výber FCS bajtov ešte nie je implementovaný

FCS sa vysiela little-endian:

```systemverilog
case (fcs_cnt_q)
  2'd0: gmii_txd_d = fcs_val_q[7:0];
  2'd1: gmii_txd_d = fcs_val_q[15:8];
  2'd2: gmii_txd_d = fcs_val_q[23:16];
  2'd3: gmii_txd_d = fcs_val_q[31:24];
endcase
```

## Problém 5: padding výpočet treba presne definovať

V `gmii_tx_mac` parameter `tx_payload_len_i` znamená Ethernet payload, teda napríklad celý IPv4 packet.

Padding:

```text
frame_no_fcs = 14 + tx_payload_len_i
padding_len  = max(0, 60 - frame_no_fcs)
```

Pre UDP HELLO:

```text
IPv4 total length = 33
14 + 33 = 47
padding = 13
```

Toto by mal robiť `gmii_tx_mac`, nie UDP vrstva.

---

# 4. `gmii_rx_mac.sv`

Tento modul je zatiaľ príliš jednoduchý.

## Problém 1: `m_axis_tlast` a `frame_done_o` nie sú priradené

V module existujú výstupy:

```systemverilog
m_axis_tlast
frame_done_o
```

ale nie sú nikde priradené. To je nehotová implementácia.

## Problém 2: bez bufferu nevieš správne vytvoriť `tlast`

GMII `rx_dv` padne až po poslednom bajte. Ak chceš `tlast` priradiť k poslednému platnému bajtu, potrebuješ aspoň 1-bajtový hold register.

Bez toho nevieš pri danom bajte vedieť, či je posledný, kým nepríde ďalší cyklus.

## Problém 3: no-preamble režim je chybný

Aktuálne:

```systemverilog
RX_IDLE:
  if (gmii_rx_dv_i && (gmii_rxd_i == 8'h55 || !EXPECT_PREAMBLE))
    state_q <= RX_PRE;

RX_PRE:
  if (gmii_rx_dv_i && gmii_rxd_i == 8'hD5)
    state_q <= RX_DATA;
```

Ak `EXPECT_PREAMBLE=0`, prvý bajt je napríklad `00` z destination MAC. FSM prejde do `RX_PRE` a potom čaká na `D5`, ktorý už nepríde. Teda no-preamble režim v skutočnosti nefunguje.

Pri `EXPECT_PREAMBLE=0` musí modul ísť rovno do dát a prvý bajt nesmie zahodiť.

## Problém 4: ignoruje `m_axis_tready`

Výstup je:

```systemverilog
assign m_axis_tvalid = (state_q == RX_DATA && gmii_rx_dv_i);
```

Toto nerešpektuje backpressure. Buď musíš jasne povedať, že downstream musí byť vždy ready, alebo vložiť FIFO.

Pre knižnicu odporúčam:

```text
gmii_rx_mac -> malý stream FIFO -> parsery
```

---

# 5. `eth_header_parser.sv`

Tento modul je stále nefunkčný.

## Problém 1: header sa nevypĺňa celý

Máš iba:

```systemverilog
4'd0: header_reg.dst_mac[47:40] <= s_axis_tdata;
// ... tu by nasledovalo naplnenie zvyšku header_reg ...
4'd13: begin
  header_reg.ethertype[7:0] <= s_axis_tdata;
  hdr_done <= 1'b1;
end
```

Chýba priradenie bajtov 1 až 12.

## Problém 2: `byte_cnt` sa zasekne na nule

Pri `byte_cnt == 0` sa vykoná:

```systemverilog
4'd0: header_reg.dst_mac[47:40] <= s_axis_tdata;
```

ale `byte_cnt` sa nezvýši. `default: byte_cnt <= byte_cnt + 1` sa nepoužije.

Čiže parser zostane navždy na byte 0.

Správne musíš inkrementovať `byte_cnt` pri každom prijatom bajte headera.

## Problém 3: `hdr_done` sa neresetuje pri ďalšom frame

Keď sa raz nastaví:

```systemverilog
hdr_done <= 1'b1;
```

nevráti sa na 0 po `tlast`.

Treba FSM:

```text
ST_HEADER
ST_PAYLOAD
ST_DROP
```

a pri konci frame návrat do `ST_HEADER`.

---

# 6. `ipv4_checksum.sv`

Toto je doplnené, ale pozor na šírku súčtu.

Aktuálne:

```systemverilog
logic [19:0] sum;
```

Súčet desiatich 16-bitových slov môže byť až:

```text
10 * 0xFFFF = 0x9FFF6
```

To sa zmestí do 20 bitov, takže šírka je OK.

Ale foldovanie iba raz:

```systemverilog
sum_final = sum[15:0] + sum[19:16];
checksum_o = ~sum_final;
```

väčšinou stačí, ale po pripočítaní carry môže vzniknúť ešte ďalší carry. Bezpečnejšie:

```systemverilog
logic [20:0] fold1;
logic [16:0] fold2;

fold1 = sum[15:0] + sum[19:16];
fold2 = fold1[15:0] + fold1[20:16];
checksum_o = ~fold2[15:0];
```

Ešte dôležitejšie: pri výpočte IP checksum musí byť checksum field v headeri nulový.

---

# 7. `ipv4_header_parser.sv`

Tento modul je stále iba skeleton.

Výstupy:

```systemverilog
src_ip_o
dst_ip_o
protocol_o
hdr_valid_o
m_axis_tlast
```

nie sú reálne generované.

Je tam iba:

```systemverilog
assign s_axis_tready = m_axis_tready;
assign m_axis_tdata  = s_axis_tdata;
assign m_axis_tvalid = s_axis_tvalid && hdr_valid_o;
```

Ale `hdr_valid_o` nemá priradenie, takže parser nefunguje.

Tento modul treba implementovať podobne ako Ethernet parser:

```text
ST_HEADER_20B
ST_VALIDATE
ST_PAYLOAD
ST_DROP
```

Minimálne validácie:

```text
version/IHL == 8'h45
protocol == 8'h11
dst_ip == local_ip_i
total_len >= 20
```

---

# 8. `udp_echo_app.sv`

Toto je zatiaľ nefunkčné ako aplikácia.

## Problém 1: `write_ptr` a `read_ptr` nemajú reset

Vždy ich musíš resetovať:

```systemverilog
if (!rst_ni) begin
  write_ptr <= '0;
  read_ptr  <= '0;
end
```

## Problém 2: `read_ptr` sa nikde nemení

Výstup:

```systemverilog
assign m_axis_tdata = fifo_mem[read_ptr];
```

ale `read_ptr` sa nikdy neinkrementuje.

## Problém 3: `m_axis_tvalid = 1'b1`

Toto je zásadne zlé:

```systemverilog
assign m_axis_tvalid = 1'b1;
```

Modul tým stále tvrdí, že má platné dáta, aj keď nič neprijal.

Musí mať FSM:

```text
ST_IDLE
ST_RX_PAYLOAD
ST_TX_META
ST_TX_PAYLOAD
```

## Problém 4: chýba `tx_meta_ready_i`

Máš:

```systemverilog
output logic tx_meta_valid_o
```

ale nemáš handshake:

```systemverilog
input logic tx_meta_ready_i
```

Bez toho nevieš bezpečne odovzdávať metadata.

## Problém 5: chýba ochrana proti overflow

Ak payload presiahne `MAX_PAYLOAD_BYTES`, buffer pretečie.

---

# 9. `mdio_master.sv`

Je to stále iba skeleton. Má správny tri-state základ:

```systemverilog
assign mdio_io = mdio_oe ? mdio_out : 1'bz;
```

Ale chýba:

```text
MDC divider
shift register
Clause 22 frame FSM
read/write opcode
turnaround
sampling MDIO inputu
busy_o
done_o pulse
error_o
```

Pre `eth_test_03` by som MDIO zatiaľ nedával ako P0. Stačí strap-only:

```systemverilog
assign eth_mdc_o   = 1'b0;
assign eth_mdio_io = 1'bz;
```

MDIO master rieš až po funkčnom GMII TX/RX.

---

# 10. `ethernet_test_03_top.sv`

Tento súbor stále nie je použiteľný.

Má iba:

```systemverilog
input wire logic sys_clk_i,
// ... ostatné porty PHY ...
```

a neplatné inštancie:

```systemverilog
gmii_rx_mac u_rx_mac (...);
eth_header_parser u_eth_parser (...);
ipv4_header_parser u_ip_parser (...);
udp_header_parser u_udp_parser (...);
udp_echo_app u_echo (...);
```

`...` nie je platná inštancia s portami. Navyše `udp_header_parser.sv` v ZIP-e neexistuje.

Top teda určite neprejde kompiláciou.

---

# 11. `tb_udp_echo_full_path.sv`

Testbench ešte nič netestuje.

Má iba:

```systemverilog
$display("Test začal...");
#10000;
$finish;
```

Neposiela:

```text
preamble
Ethernet header
IPv4 header
UDP header
payload
FCS
```

a nekontroluje `txd/txen`.

Navyše inštancuje porty:

```systemverilog
.eth_rx_clk_i(clk)
.eth_tx_clk_i(clk)
.rst_ni(rst_n)
.eth_rxd_i(rxd)
...
```

ktoré v aktuálnom `ethernet_test_03_top.sv` ešte neexistujú.

---

# Odporúčaný ďalší postup

Nerobil by som teraz ďalšie rozširovanie topu. Treba ísť modul po module.

## Krok 1 — opraviť a otestovať `crc32_eth`

Pridať test:

```text
tb_crc32_eth
```

Overiť:

```text
"123456789" -> 0xCBF43926
```

Až potom používať CRC v MAC.

## Krok 2 — dokončiť `gmii_tx_mac`

Implementovať:

```text
- čítače
- výstupný mux
- CRC clear/en
- FCS byte order
- padding
- IFG
- valid/ready handshake
```

Pridať testy:

```text
tb_gmii_tx_mac_min_frame
tb_gmii_tx_mac_no_padding
tb_gmii_tx_mac_ifg
```

Toto je najlepší najbližší cieľ.

## Krok 3 — dokončiť `gmii_rx_mac`

Najprv bez FCS checku:

```text
- with preamble
- no preamble
- rx_er abort
- korektný tlast
```

Až potom FCS checker.

## Krok 4 — dokončiť `eth_header_parser`

Musí mať FSM a nesmie sa zaseknúť na byte 0.

## Krok 5 — až potom IPv4/UDP vrstvy

Doplniť:

```text
ipv4_header_parser
udp_header_parser
udp_header_builder
ipv4_header_builder
```

Momentálne ešte chýbajú alebo sú skeleton.

---

## Priorita chýb

### P0 — kompilácia

```text
ethernet_test_03_top.sv obsahuje ...
udp_header_parser.sv chýba
gmii_tx_mac nie je dokončený
gmii_rx_mac nepriraďuje tlast/frame_done
ipv4_header_parser nemá implementáciu
```

### P1 — Ethernet správnosť

```text
crc32_eth treba opraviť na Ethernet LSB-first
gmii_tx_mac musí správne počítať FCS/padding/IFG
gmii_rx_mac musí vedieť no-preamble režim
eth_header_parser musí korektne parsovať 14 bajtov
```

### P2 — stream korektnosť

```text
udp_echo_app musí mať FSM
m_axis_tvalid nesmie byť stále 1
read_ptr sa musí posúvať
metadata musia mať valid/ready handshake
```

---

## Záver

Doplnil si viac kódu, ale väčšina kritických modulov je stále na úrovni návrhu. Najbližšie by som sa sústredil len na:

```text
crc32_eth + gmii_tx_mac
```

Keď budeš mať `gmii_tx_mac`, ktorý vie zo streamu vyrobiť presný Ethernet frame s paddingom, FCS a IFG, máš prvý skutočný základ knižnice. Potom pridaj `gmii_rx_mac`. Až potom má zmysel integrovať IPv4/UDP/top-level echo.
