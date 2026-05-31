Podľa aktuálneho stavu by som to ako expert zhrnul takto:

```text
Simulácia: veľmi dobrá
RX/TX architektúra: rozumná
HW problém: už je lokalizovaný na RX parser vstup / prvé vrstvy
Najpravdepodobnejšie príčiny: preambula/SFD režim, RXD bit/byte mapovanie, alebo zvyškový ETH_RXC timing
```

Keďže **LED2 bliká**, PHY ti naozaj dáva `RXDV`. Keďže **LED3 nikdy**, problém je pred alebo v momente:

```text
gmii_rx_mac -> eth_header_parser -> ipv4_header_parser -> udp_header_parser -> udp_rx_meta_assembler
```

Teda teraz už netreba riešiť TX, UDP echo app ani `gmii_tx_mac`. Tie sa vôbec nespustia.

---

# 1. Najpravdepodobnejší problém: preambula/SFD

V aktuálnom top-e máš:

```systemverilog
parameter bit EXPECT_PREAMBLE = 1'b1
```

a v `project.yaml` nevidím parameter override. Vygenerovaný `soc_top.sv` inštancuje:

```systemverilog
ethernet_test_03_top ethernet_test_03_top (
  ...
);
```

bez:

```systemverilog
#(
  .EXPECT_PREAMBLE(...)
)
```

Čiže HW build používa default:

```text
EXPECT_PREAMBLE = 1
```

`gmii_rx_mac` potom čaká:

```text
55 55 ... D5
```

Ak RTL8211EG v tvojej konfigurácii začne `RXD` stream až od destination MAC, parser nikdy neprejde do dát. LED2 bude blikať, ale LED3 nikdy.

Toto presne sedí na symptóm:

```text
RXDV aktivita áno
UDP accepted nikdy
TX nikdy
```

## Prvý test, ktorý by som spravil

Sprav nový HW build s:

```systemverilog
EXPECT_PREAMBLE = 1'b0
```

Nie iba v testbenchi. Musí sa to dostať do reálneho `soc_top.sv`.

Do `project.yaml`/IP parametrov doplniť:

```yaml
params:
  EXPECT_PREAMBLE: false
```

A skontrolovať, že vygenerovaný top má:

```systemverilog
ethernet_test_03_top #(
  .EXPECT_PREAMBLE(1'b0)
) ethernet_test_03_top (
  ...
);
```

Ak pri `EXPECT_PREAMBLE=0` začne LED3 blikať, máš potvrdenú príčinu: **PHY neposiela preambulu/SFD do FPGA tak, ako očakáva `gmii_rx_mac`**.

---

# 2. Ešte lepšie: urob `gmii_rx_mac` auto-detekčný

Namiesto dvoch buildov by som cieľovo upravil RX MAC tak, aby vedel prijať oba režimy:

```text
A) stream obsahuje preambulu/SFD
B) stream začína priamo destination MAC
```

Teraz máš:

```systemverilog
if (EXPECT_PREAMBLE && gmii_rxd_i == 8'h55) state_d = RX_PRE;
else if (!EXPECT_PREAMBLE)                  state_d = RX_DATA;
```

To je build-time voľba. Pre HW bring-up je lepšie mať debug parameter:

```systemverilog
parameter bit AUTO_PREAMBLE = 1'b1
```

Princíp:

```text
pri prvom RXDV byte:
  ak byte == 0x55, skús preamble/SFD režim
  inak začni rovno DATA režim a prvý byte nevyhoď
```

Pozor: auto režim musí zachovať prvý non-55 byte. Nesmie sa stať, že destination MAC byte 0 stratíš.

---

# 3. Druhý veľmi pravdepodobný problém: RXD bit/byte mapovanie

Ak preambula/SFD naozaj prichádza, ďalší kandidát je zlé poradie `ETH_RXD[7:0]`.

V `board.tcl` máš:

```tcl
ETH_RXD[0] -> K22
ETH_RXD[1] -> L21
ETH_RXD[2] -> L22
ETH_RXD[3] -> M21
ETH_RXD[4] -> N21
ETH_RXD[5] -> N22
ETH_RXD[6] -> P21
ETH_RXD[7] -> P22
```

Ak je board definícia bitovo otočená, FPGA neuvidí:

```text
55 D5 00 0A 35 ...
```

ale napríklad bit-reversed hodnoty. Potom MAC/IP/UDP filter všetko zahodí.

Pre niektoré bajty je to zradné:

```text
0x55 bit-reversed = 0xAA
0xD5 bit-reversed = 0xAB
0x00 ostane 0x00
```

Čiže ak PHY posiela preambulu, ale ty máš RXD bit order otočený, `gmii_rx_mac` nikdy neuvidí `0x55`/`0xD5`.

## Ako to overiť bez osciloskopu

Pridaj debug sampler prvých bajtov po `RXDV` a zobraz ich cez LED v režime „nibble display“.

Najjednoduchšie:

```text
po nábehu RXDV zachyť prvé 4 bajty:
  rx_dbg_b0
  rx_dbg_b1
  rx_dbg_b2
  rx_dbg_b3
```

Potom pomocou prepínača/počítadla zobrazuj na LED:

```text
LED[3:0] = low nibble / high nibble vybraného bajtu
LED4 = valid capture
LED5 = rx_er_seen
```

Keď pošleš UDP packet, očakávaš podľa režimu buď:

```text
s preambulou:
  b0 = 55
  b1 = 55
  ...
  neskôr D5

bez preambuly:
  b0 = 00
  b1 = 0A
  b2 = 35
  b3 = 01
```

Ak vidíš `AA` namiesto `55`, alebo zvláštne hodnoty, riešiš bit order/pin mapping.

---

# 4. Tretí problém: timing stále nie je úplne uzavretý

Aktuálne:

```text
ETH_RXC slow 85°C slack = -0.282 ns
```

To je už oveľa lepšie než `-7.18 ns`, ale stále je to fail. Pri laboratórnej teplote môže fungovať, ale nesmieš na to spoliehať.

Ak parser dropuje **všetky** rámce, preambula/bit mapping je pravdepodobnejší problém než náhodný timing bit error. Ale timing fail stále musíš uzavrieť pred tým, než budeš hľadať subtílne chyby.

## Čo by som spravil

Pipelining týchto ciest:

```text
udp_echo_app.rx_meta_q.payload_len -> u_meta_fifo.mem
udp_ipv4_tx_builder.hdr_cnt_q      -> u_pkt_fifo.mem
```

Najmä `meta_fifo` write data by som registroval:

```systemverilog
logic [95:0] meta_wr_data_q;
logic        meta_wr_valid_q;

always_ff @(posedge eth_rx_clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    meta_wr_valid_q <= 1'b0;
    meta_wr_data_q  <= '0;
  end else begin
    meta_wr_valid_q <= 1'b0;

    if (txb_tvalid && pkt_wr_ready && txb_tlast && meta_wr_ready) begin
      meta_wr_data_q  <= {meta_latch_dst_q, meta_latch_src_q};
      meta_wr_valid_q <= 1'b1;
    end
  end
end
```

Ale pozor: toto mení handshake, lebo `meta_wr_ready` musíš rešpektovať. Teraz máš:

```systemverilog
assign meta_wr_valid = txb_tvalid && pkt_wr_ready && txb_tlast;
```

a `meta_wr_ready` vlastne neblokuje packet writer. To je teoreticky problém, aj keď FIFO hĺbka 4 ho v praxi zakryje.

Pre robustnosť by som spravil malý TX packet commit FSM.

---

# 5. FCS na konci rámca pravdepodobne nie je dôvod dropu

Status uvádza:

```text
FCS nie je stripovaný
```

Ale `udp_header_parser` je navrhnutý tak, že:

```text
forwarduje iba payload_len bajtov podľa udp_len
zvyšok do s_axis_tlast zahodí ako padding/FCS
```

A testy to pokrývajú:

```text
tb_udp_header_parser: padding + FCS discarded
tb_rx_path: frame including padding + FCS PASS
```

Čiže FCS na konci by nemal spôsobiť, že LED3 nikdy neblikne. Keby sa rámec dostal až do UDP parsera, `hdr_pre_valid_o` by mal vzniknúť už pri 8. bajte UDP headera, dávno pred FCS.

Preto FCS teraz nepovažujem za hlavného kandidáta.

---

# 6. LED3 je príliš neskorý signál

LED3 je teraz:

```systemverilog
.udp_accept_i(rx_meta_valid)
```

To znamená, že svieti až keď prejde:

```text
gmii_rx_mac
eth_header_parser
ipv4_header_parser
udp_header_parser
udp_rx_meta_assembler
```

To je príliš neskoro na diagnostiku. Teraz potrebuješ vedieť, kde sa rámec stratí.

## Navrhujem dočasný debug LED build

Namiesto finálnej LED mapy sprav 2–3 buildy.

### Debug build A — vrstvy

```text
LED0 = heartbeat
LED1 = phy_reset_done
LED2 = raw RXDV
LED3 = gmii_rx_mac.frame_done_o
LED4 = eth_header_parser.hdr_valid_o
LED5 = ipv4_header_parser.hdr_valid_o
```

Ak:

```text
LED3 nebliká:
  gmii_rx_mac nedokončil frame — preambula/SFD/RXDV/tlast problém

LED3 bliká, LED4 nie:
  L2 MAC filter drop alebo nesprávne RXD bajty

LED4 bliká, LED5 nie:
  IPv4 parser drop — IP header nesedí

LED5 bliká, ale UDP accepted nie:
  UDP port/length/parser problém
```

### Debug build B — drop signály

```text
LED3 = eth_header_parser.drop_o
LED4 = ipv4_header_parser.drop_o
LED5 = udp_header_parser.drop_o
```

Tým hneď zistíš, ktorá vrstva zahadzuje.

### Debug build C — preambula/no-preamble

```text
LED3 = saw_55
LED4 = saw_D5
LED5 = first_data_seen
```

Toto je najrýchlejšia odpoveď na otázku, či PHY posiela preambulu/SFD a či RXD bit order sedí.

---

# 7. Potrebné debug signály v RTL

Do `gmii_rx_mac` by som dočasne pridal:

```systemverilog
output logic dbg_saw_55_o,
output logic dbg_saw_d5_o,
output logic dbg_data_started_o,
output logic [7:0] dbg_first_byte_o,
output logic       dbg_first_byte_valid_o
```

Implementačne:

```systemverilog
if (!rst_ni) begin
  dbg_saw_55_o <= 1'b0;
  dbg_saw_d5_o <= 1'b0;
end else begin
  if (gmii_rx_dv_i && gmii_rxd_i == 8'h55)
    dbg_saw_55_o <= 1'b1;

  if (gmii_rx_dv_i && gmii_rxd_i == 8'hD5)
    dbg_saw_d5_o <= 1'b1;
end
```

A pre prvý byte:

```systemverilog
if (m_axis_tvalid && !dbg_first_byte_valid_o) begin
  dbg_first_byte_o       <= m_axis_tdata;
  dbg_first_byte_valid_o <= 1'b1;
end
```

Potom vieš zistiť:

```text
saw_55 = 0, saw_d5 = 0:
  buď PHY nedáva preambulu, alebo RXD bit order zlý

saw_55 = 1, saw_d5 = 0:
  SFD sa nenašlo, bit error alebo preamble handling problém

saw_55 = 1, saw_d5 = 1, frame_done = 0:
  RXDV/tlast problém

frame_done = 1, L2 hdr_valid = 0:
  MAC header nesedí
```

---

# 8. Ešte jeden podozrivý bod: `ALLOW_NO_PREAMBLE` nič nerobí

Inštancuješ:

```systemverilog
gmii_rx_mac #(
  .EXPECT_PREAMBLE  (EXPECT_PREAMBLE),
  .ALLOW_NO_PREAMBLE(1'b1)
)
```

Ale v module `ALLOW_NO_PREAMBLE` je len „reserved for future use“. Reálne nič nemení.

To môže byť mätúce. Ak si myslíš, že tým povoľuješ no-preamble režim, tak nie. Skutočné správanie riadi iba:

```systemverilog
EXPECT_PREAMBLE
```

Preto by som buď:

```text
A. odstránil ALLOW_NO_PREAMBLE
```

alebo ho implementoval.

---

# 9. Konkrétne poradie ďalších krokov

## Krok 1 — spraviť no-preamble HW build

```text
EXPECT_PREAMBLE = 0
```

Ak LED3 začne blikať, problém vyriešený.

## Krok 2 — ak nie, spraviť debug vrstvy

LED mapa:

```text
LED3 = gmii_rx_mac.frame_done
LED4 = eth_header_parser.hdr_valid
LED5 = ipv4_header_parser.hdr_valid
```

Toto ti povie, kde sa dropuje.

## Krok 3 — pridať saw_55/saw_d5 debug

Ak `frame_done` nebliká, potrebuješ vedieť:

```text
vidím 0x55?
vidím 0xD5?
aký je prvý byte?
```

## Krok 4 — preveriť RXD bit order

Ak nevidíš `55/D5` ani v preamble build-e, skús debug build s bit-reverse:

```systemverilog
wire [7:0] eth_rxd_dbg_w = {
  eth_rxd_i[0],
  eth_rxd_i[1],
  eth_rxd_i[2],
  eth_rxd_i[3],
  eth_rxd_i[4],
  eth_rxd_i[5],
  eth_rxd_i[6],
  eth_rxd_i[7]
};
```

a pripoj `gmii_rx_mac.gmii_rxd_i` na `eth_rxd_dbg_w`.

Ak zrazu parser začne fungovať, board pin bit order je otočený.

## Krok 5 — uzavrieť timing

Aj keď nájdeš parser problém, timing `-0.282 ns` ešte oprav. Pre finálny build musí byť:

```text
ETH_RXC slow 85°C slack >= 0
```

---

# 10. Najpravdepodobnejší scenár podľa symptómov

Moje poradie pravdepodobnosti:

```text
1. PHY neposiela preambulu/SFD do FPGA alebo RXDV začína až od destination MAC.
   Súčasný HW build má EXPECT_PREAMBLE=1, takže gmii_rx_mac neprepustí nič.

2. RXD bit order / pin mapping je otočený alebo nesedí.
   Parser potom nevidí 0x55/D5 ani správnu MAC.

3. Zvyškový ETH_RXC timing fail spôsobuje bitové chyby.
   Menej pravdepodobné ako 1/2, ale stále nutné opraviť.

4. FCS na konci rámca.
   Málo pravdepodobné ako príčina LED3=0, lebo UDP parser má flush podľa udp_len a sim to testuje.
```

---

## Najbližší odporúčaný experiment

Urob tieto dva buildy, nie ďalší veľký refaktor:

```text
Build A:
  EXPECT_PREAMBLE = 0
  LED3 = rx_meta_valid
  ostatné LED rovnako

Build B:
  EXPECT_PREAMBLE = 1
  LED3 = gmii_rx_mac.frame_done
  LED4 = eth_header_parser.hdr_valid
  LED5 = ipv4_header_parser.hdr_valid
```

Ak Build A začne odpovedať alebo aspoň LED3 blikne, máš hotovo: preamble režim bol zlý.

Ak Build B ukáže `frame_done=0`, problém je v `gmii_rx_mac` vstupnej interpretácii, teda preambula/bit order/RXD timing.

Ak Build B ukáže `frame_done=1`, ale `eth_hdr_valid=0`, problém je MAC header hodnota — najčastejšie RXD bit order alebo nesprávny destination MAC na drôte.
