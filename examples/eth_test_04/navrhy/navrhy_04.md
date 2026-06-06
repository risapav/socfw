Spracoval som novú verziu:

```text id="yfhwhq"
eth_test_04(1).zip
SHA-256: ac7f2591559a6cf845601724f09c4e399d4b55940a247de6b73090f3dd599271
SHA-1:   109b6143d21e12bfd207b3f874e6161315493c89
MD5:     73b6eebf020776671f9df09f23ca89b2
```

Pozor: `SHA-1` je rovnaký ako pri predošlom `eth_test_04.zip`, ale `SHA-256` aj veľkosť ZIP-u sú iné. Nový ZIP je výrazne menší, lebo už neobsahuje veľké PDF `8023-2022.pdf`.

Dôležité nové súbory:

```text id="sbtlwn"
output_files/soc_top.sof
SHA-256: 93a2ae16d82535641c4f06b5e0390b481c3dc68bc77dc4c90d39ddd41689fd0c

rtl/eth/mac/gmii_tx_mac.sv
SHA-256: 06550ee738b413ddae2c2001e72b2f7f82fc7f615ca4ab698b31176004ff3868

rtl/eth/mac/gmii_rx_mac.sv
SHA-256: 20c12bee8b30d7fb05006b32d5b29296da3788250d475f61b1c0d7a0bca19bfe

test_loopback.py
SHA-256: f2a189e4e9fe637ec62bd44d046d8f6296d03f7c9ae5a74ddebae66a12bcc8a9
```

## Čo sa zmenilo oproti predošlej verzii

Zapracoval si dve dôležité veci:

```text id="1ia7vq"
1. gmii_tx_mac už vkladá 7 bajtov preambuly 0x55 pred streamom.
2. test_loopback.py už ignoruje PACKET_OUTGOING a má broadcast režim.
```

Toto je dobrý posun. Pôvodné dve veľké chyby raw loopback testu sú tým výrazne zredukované.

---

# 1. TX preambula je pridaná správnym smerom

V `gmii_tx_mac.sv` pribudol stav:

```systemverilog id="fsfg2r"
ST_PREAMBLE
```

a v ňom:

```systemverilog id="gpje1c"
gmii_tx_en_o <= 1'b1;
gmii_tx_er_o <= 1'b0;
gmii_txd_o   <= 8'h55;
```

Po siedmich bajtoch:

```systemverilog id="2gtcz2"
if (preamble_cnt_q == 3'd6) begin
  state_q       <= ST_DATA;
  s_axis_tready <= 1'b1;
end
```

To znamená, že TX pošle:

```text id="selmp8"
55 55 55 55 55 55 55
```

a až potom pustí prvý AXI byte. Keďže RX stream aktuálne začína SFD `0xD5`, výsledok na GMII TX linke má byť:

```text id="gnrlhn"
55 55 55 55 55 55 55 D5 ...
```

To je správne pre aktuálny **raw-SFD loopback kontrakt**.

---

# 2. Test skript je podstatne lepší

`test_loopback.py` už robí:

```python id="z19bpd"
data, addr = sock.recvfrom(4096)
if addr[2] == PACKET_OUTGOING:
    continue
```

Tým sa znižuje riziko falošného PASS-u na vlastnom odoslanom frame.

Pribudol aj broadcast režim:

```bash id="9s1y5c"
make loopback-test-bcast
```

To je dôležité, pretože aktuálny FPGA loopback stále vracia frame byte-for-byte. Ak PC pošle unicast:

```text id="m2j28q"
DST = FPGA_MAC
SRC = PC_MAC
```

FPGA vráti:

```text id="io4j0q"
DST = FPGA_MAC
SRC = PC_MAC
```

a PC NIC ho nemusí prijať ako HOST frame. Broadcast test je preto pre túto raw fázu vhodnejší:

```text id="u7agqn"
DST = FF:FF:FF:FF:FF:FF
SRC = PC_MAC
```

FPGA ho vráti ako broadcast a PC ho má šancu zachytiť.

---

# 3. Quartus timing je stále dobrý

Nový build:

```text id="8q7bar"
Fitter Status: Successful
Logic elements: 252
Registers: 236
Memory bits: 20,480
PLL: 1
```

Timing:

```text id="66sih4"
Slow 85C setup:
ETH_RXC     +1.997 ns
ETH_TX_CLK  +2.323 ns
SYS_CLK     +5.305 ns

Slow 85C hold:
ETH_RXC     +0.418 ns
ETH_TX_CLK  +0.449 ns
SYS_CLK     +0.462 ns
```

Oproti predchádzajúcej verzii je to mierne horšie, ale stále veľmi dobré pre diagnostický dizajn.

---

# 4. Stále je to raw loopback, nie čistý MAC datapath

Aktuálny RX stále posiela do streamu:

```text id="ldvvf6"
byte 0      = SFD 0xD5
byte 1..6   = DST_MAC
byte 7..12  = SRC_MAC
byte 13..14 = EtherType
byte 15..   = payload
last 4      = FCS
```

TX k tomu iba pridá preambulu.

Čiže aktuálny datapath je:

```text id="3h43ra"
GMII RX
  -> stream vrátane SFD/header/payload/FCS
  -> async FIFO
  -> TX pridá 7x55
  -> stream vrátane D5/header/payload/FCS
  -> GMII TX
```

To je teraz použiteľné ako **raw diagnostický loopback**.

Nie je to ešte architektúra, ktorú si popísal v poslednej správe:

```text id="2xa3i7"
RX skontroluje frame, CRC, MAC, veľkosť a von pustí iba očistený payload.
TX vezme payload, doplní header, otočí MAC a vypočíta nové CRC.
```

---

# 5. Najväčší aktuálny problém: `gmii_tx_mac` handshake má latentný bug

V `ST_PREAMBLE` nastavíš:

```systemverilog id="n5xcac"
s_axis_tready <= 1'b1;
```

V nasledujúcom cykle `ST_DATA` sa očakáva, že platí:

```text id="xbyi8a"
ak s_axis_tvalid=1, tak sa prenesie prvý byte, teda SFD
```

To bude fungovať s tvojím `async_fifo`, pretože `rd_ready_i=tx_tready` spustí čítanie a `rd_valid_o` je registrovaný FWFT výstup. Ale je tu slabé miesto:

```text id="mtoyfs"
TX MAC používa s_axis_tvalid ako dostupnosť dát,
ale nie explicitný fire = s_axis_tvalid && s_axis_tready.
```

V `ST_DATA` máš:

```systemverilog id="u0g9en"
if (s_axis_tvalid) begin
  gmii_txd_o <= s_axis_tdata;
  ...
end else begin
  // Underflow
end
```

Správnejší AXI-S štýl je:

```systemverilog
fire_w = s_axis_tvalid && s_axis_tready;
```

a TX dáta posielať iba pri `fire_w`.

Teraz je to čiastočne maskované tým, že počas `ST_DATA` držíš `s_axis_tready=1`. Ale pri budúcej úprave, keď TX bude generovať header/CRC/padding a bude payload stream dočasne brzdiť, tento štýl ťa dobehne.

Odporúčanie: už teraz prepisovať TX MAC na explicitný handshake:

```systemverilog id="d4z4qo"
logic axis_fire_w;
assign axis_fire_w = s_axis_tvalid && s_axis_tready;
```

a v `ST_DATA`:

```systemverilog id="gnwlu7"
if (axis_fire_w) begin
  gmii_tx_en_o <= 1'b1;
  gmii_txd_o   <= s_axis_tdata;
  ...
end
```

---

# 6. RX modul ešte nemá validáciu, CRC ani stripovanie

`gmii_rx_mac.sv` stále uvádza:

```text id="nxg1vp"
stat_rx_err_bad_fcs: stub 0 -- requires CRC32 integration
```

A kód na konci frame robí:

```systemverilog id="gbo4vy"
stat_rx_err_bad_fcs <= 1'b0;
```

Čiže aktuálne RX:

```text id="d2mq46"
nekontroluje FCS,
nestripuje SFD,
nestripuje Ethernet header,
nestripuje FCS,
nefiltroval LOCAL_MAC,
neoveruje EtherType voči metadátam,
neprodukuje payload_len.
```

To je v poriadku pre raw loopback fázu, ale ďalší krok musí byť nový modul, nie len rozšírenie tohto raw konvertora.

Navrhoval by som premenovať aktuálny modul na:

```text id="8vgjud"
gmii_rx_raw_axis.sv
```

a nový čistý MAC modul pomenovať:

```text id="1c14kc"
eth_rx_mac.sv
```

Podobne aktuálny TX:

```text id="2jjq7c"
gmii_tx_raw_axis.sv
```

a nový čistý TX:

```text id="m8k2kq"
eth_tx_mac.sv
```

Tým sa nezmiešajú dva odlišné kontrakty.

---

# 7. `async_fifo` je použiteľný, ale pozor na ignorované `wr_ready`

V top-e máš:

```systemverilog id="qw5o8q"
.wr_valid_i (rx_tvalid),
.wr_ready_o (),              // RX MAC has no backpressure input
```

To je pre RX MAC normálne, linka sa nedá zastaviť. Ale znamená to:

```text id="rn0bsh"
ak FIFO pretečie, frame sa potichu poškodí.
```

Pre diagnostiku by som minimálne pridal výstup:

```systemverilog id="ox5x4y"
fifo_overflow_sticky <= rx_tvalid && !fifo_wr_ready;
```

a dať ho na debug bit. Bez toho môžeš mylne analyzovať CRC/MAC problém, keď v skutočnosti FIFO zahodilo bajty.

V čistom MAC návrhu by RX store-and-forward buffer tiež mal mať:

```text id="admlko"
overflow flag
dropped_frame flag
status counter
```

---

# 8. `async_fifo` read side je prakticky FWFT, ale názov komentára je trochu zavádzajúci

V kóde:

```systemverilog id="wcsbqg"
assign do_rd_w = !empty_w && (!oq_valid_q || rd_ready_i);
```

a potom:

```systemverilog id="0bt8xu"
rd_data_q  <= mem[rptr_bin_q[ADDR_W-1:0]];
oq_valid_q <= 1'b1;
```

To znamená, že `rd_valid_o` sa objaví až po prefetch cykle. Nie je to čistý „combinational FWFT“, ale registrovaný prefetch. To je v poriadku, len pri TX preambule to vytvára časovanie:

```text id="29nf3z"
ST_IDLE vidí tx_tvalid=1 až po prefetch
ST_PREAMBLE drží tready=0
na poslednom preamble cykle dá tready=1
ďalší cyklus už DATA použije prvý byte
```

Momentálne to sedí.

---

# 9. `test_loopback.py`: ešte jedna vec na zlepšenie

Skript teraz pri PASS vypisuje `src=...`, ale nekontroluje, či zdroj dáva zmysel.

Pri raw byte-for-byte loopback bude vrátený frame mať:

```text id="w45jhj"
src = PC_MAC
```

nie FPGA MAC, pretože FPGA zatiaľ nemení header.

To je očakávané. Ale pre budúci čistý MAC echo má byť:

```text id="ti5oyx"
src = FPGA_MAC
dst = PC_MAC
```

Navrhol by som pridať parameter:

```text id="xpinr3"
--mode raw
--mode clean
```

Pre `raw` režim:

```text id="ie23es"
broadcast odporúčaný,
src môže byť PC_MAC,
marker offset 15 znamená SFD v stream-e.
```

Pre `clean` režim:

```text id="0uenxx"
src musí byť FPGA_MAC,
dst musí byť PC_MAC,
marker offset musí byť 14.
```

Tým sa vyhneš tomu, že test ostane raw aj po prechode na čistý MAC.

---

# 10. Odporúčaný ďalší krok v projekte

Aktuálnu verziu by som bral ako **Fázu A — raw loopback sanity test**.

## Fáza A: overiť fyziku

Spusti:

```bash id="nzhfw4"
make program
sleep 5 && ./diag.sh 2>&1
make loopback-sniff
```

V druhom termináli:

```bash id="av1u1k"
make loopback-test-bcast
```

Očakávaný výsledok:

```text id="a4rlwq"
PASS aspoň pre krátke a stredné frame
offset=15 pravdepodobný, pretože FPGA echo obsahuje SFD ako byte pred Ethernet headerom
```

Ak `offset=15`, znamená to:

```text id="pvc7r5"
raw RX stream naozaj obsahuje SFD pred DST_MAC
```

To je dobrá informácia, nie chyba.

Ak `offset=14`, znamená to:

```text id="x0d3e2"
niekde sa SFD stratilo alebo NIC/driver zachytáva frame až od Ethernet headeru
```

To treba interpretovať opatrne.

---

## Fáza B: vytvoriť čistý RX MAC

Nový modul:

```text id="3eymfs"
eth_rx_mac_clean.sv
```

Kontrakt:

```text id="na3s48"
vstup:  GMII RX
výstup: payload-only AXIS
meta:   dst_mac, src_mac, ethertype, payload_len, flags
status: fcs_ok, mac_match, too_short, too_long, rx_er, drop_reason
```

V prvej verzii by som spravil store-and-forward:

```text id="x72d5p"
1. zachytiť frame do bufferu
2. počítať CRC
3. na konci overiť FCS
4. ak OK a MAC sedí, vypustiť payload
5. ak nie, zahodiť a zapísať status
```

---

## Fáza C: vytvoriť čistý TX MAC

Nový modul:

```text id="hoxq99"
eth_tx_mac_clean.sv
```

Kontrakt:

```text id="8t9q5q"
vstup:  payload-only AXIS + tx_meta
výstup: GMII TX
```

TX generuje:

```text id="8e3w2x"
7x55
D5
DST MAC
SRC MAC
EtherType
payload
padding
FCS
IFG
```

Pre echo:

```text id="tom6ee"
dst_mac = rx_meta.src_mac
src_mac = LOCAL_MAC
ethertype = rx_meta.eth_type_len
payload_len = rx_meta.payload_len
```

---

## Fáza D: diagnostika paralelne

Pridať tri typy diagnostiky:

```text id="fsubck"
1. sticky LED/J10/J11 event flags
2. per-frame status record
3. trace FIFO pre prvých 64 bajtov raw RX frame
```

Dôležité: trace FIFO nesmie blokovať RX. Ak je plné, nastaví sa `diag_overflow`.

---

# 11. Najdôležitejší záver k novej verzii

Nová verzia je lepšia a už dáva zmysel ako raw GMII loopback test:

```text id="b07ozf"
+ TX preambula je doplnená
+ test ignoruje PACKET_OUTGOING
+ broadcast režim je doplnený
+ timing je stále dobrý
```

Ale ešte to nie je cieľový MAC návrh:

```text id="24cu0y"
- RX nepočíta CRC/FCS
- RX nekontroluje LOCAL_MAC
- RX nestripuje header/FCS
- TX negeneruje header
- TX neswapuje MAC
- TX nepočíta nové CRC/FCS
```

Pre ďalšiu fázu by som ponechal tieto raw moduly ako diagnostický nástroj a začal paralelne písať `eth_rx_mac_clean` + `eth_tx_mac_clean`. To nám dovolí porovnávať:

```text id="n392ff"
raw path:   čo skutočne lezie z PHY
clean path: čo spracuje MAC vrstva
```

To je najbezpečnejšia cesta, aby sme znova nehádali, či problém vzniká na GMII, v MAC parseri, alebo v aplikačnej echo logike.
