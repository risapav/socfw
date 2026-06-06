Spracoval som nový projekt priamo z nahraného ZIP-u:

```text
eth_test_04.zip
SHA-256: 1b7ce44c98173fb65c361541dca39ea4da981a6e784438b964b6abf8fca35016
SHA-1:   109b6143d21e12bfd207b3f874e6161315493c89
MD5:     73b6eebf020776671f9df09f23ca89b2
```

Dôležité súbory:

```text
output_files/soc_top.sof
SHA-256: ac7acb6e10fab65258fd9da1339d8c1d0623f2c54768f2a1f62b52e7ff46e9d9

rtl/eth/ethernet_test_04_top.sv
SHA-256: 0941b70016f6137427ed232878c991c25ccbd79d233527a88e6acfc166e403b8

rtl/eth/mac/gmii_rx_mac.sv
SHA-256: 20c12bee8b30d7fb05006b32d5b29296da3788250d475f61b1c0d7a0bca19bfe

rtl/eth/mac/gmii_tx_mac.sv
SHA-256: ea08a14788df72b50572a426651a9abafe26b6ac166a563d8e8a0aaf4ba40e3d
```

## Krátky verdikt

`eth_test_04` je dobrý diagnostický smer: zjednodušuje problém na:

```text
GMII RX -> AXI-Stream -> async FIFO -> GMII TX
```

Tým sa odstraňuje UDP/IP parser, meta FIFO, echo app a CRC builder z `eth_test_03`. Na hľadanie RX offsetu je to správna filozofia.

Ale aktuálna implementácia má podľa mňa **tri zásadné návrhové problémy**, ktoré môžu spôsobiť, že HW testy budú zavádzajúce alebo vôbec neprejdú:

1. **TX MAC neposiela preambulu `55...55 D5`.**
   Aktuálny RX stream obsahuje SFD `0xD5`, ale TX MAC ho iba prepošle ako prvý bajt s `TXEN=1`. Chýba sedem bajtov `0x55`.

2. **Raw loopback vracia Ethernet frame byte-for-byte, čiže destination MAC ostane FPGA MAC.**
   PC NIC nemusí takýto echo frame vôbec doručiť do systému, pretože frame je stále adresovaný na `00:0a:35:01:fe:c0`, nie na MAC PC.

3. **`test_loopback.py` môže falošne PASSnúť na vlastnom odoslanom frame.**
   AF_PACKET socket s `ETH_P_ALL` môže vidieť aj outgoing frame. Skript hľadá iba MAGIC marker a nekontroluje, či zachytený frame prišiel späť z FPGA. Teda môže zachytiť vlastný TX frame ešte pred akoukoľvek FPGA odpoveďou.

---

# 1. Stav projektu a Quartus

`ETH_TEST_04_STATUS.md` hovorí:

```text
RTL zatiaľ neimplementovaný
```

Ale ZIP už obsahuje implementáciu a úspešný Quartus build:

```text
Fitter Status: Successful
Quartus: 25.1std Lite
Device: EP4CE55F23C8
Logic elements: 243 / 55,856
Registers: 232
Memory bits: 20,480
PLLs: 1
```

Timing summary je výrazne lepší než pri eth_test_03:

```text
Slow 85C setup:
ETH_RXC     +2.153 ns
ETH_TX_CLK  +2.532 ns
SYS_CLK     +4.938 ns

Slow 85C hold:
ETH_RXC     +0.444 ns
ETH_TX_CLK  +0.449 ns
SYS_CLK     +0.462 ns
```

Toto je dobrý stav. Interný timing už nie je na hrane ako pri `+0.012 ns` v eth_test_03.

---

# 2. Piny a clocky

Pin assignment vyzerá konzistentne:

```text
ETH_RXC      R19
ETH_RXDV     K21
ETH_RXER     R21
ETH_RXD[0]   K22
ETH_RXD[1]   L21
ETH_RXD[2]   L22
ETH_RXD[3]   M21
ETH_RXD[4]   N21
ETH_RXD[5]   N22
ETH_RXD[6]   P21
ETH_RXD[7]   P22

ETH_GTX_CLK  U22
ETH_TXEN     V21
ETH_TXER     AA18
ETH_TXD[0]   V22
ETH_TXD[1]   W22
ETH_TXD[2]   Y21
ETH_TXD[3]   Y22
ETH_TXD[4]   AA20
ETH_TXD[5]   AB19
ETH_TXD[6]   AA19
ETH_TXD[7]   AB18
```

Pozitívne:

```text
ETH_RXD[*] má FAST_INPUT_REGISTER
ETH_RXDV má FAST_INPUT_REGISTER
ETH_RXER má FAST_INPUT_REGISTER
ETH_TXD[*] má FAST_OUTPUT_REGISTER
ETH_TXEN má FAST_OUTPUT_REGISTER
ETH_TXER má FAST_OUTPUT_REGISTER
```

Fitter potvrdzuje, že tieto registre boli naozaj zabalené do IO blokov.

Stále zostáva známy problém:

```text
ETH_RXC je na R19 a nie je dedicated clock pin.
```

Quartus hlási:

```text
Pin ETH_RXC~input drives global or regional clock Global Clock,
but is not placed in a dedicated clock pin position
```

To je rovnaký board-level limit ako predtým. V tomto projekte to zatiaľ nevyzerá ako okamžitý problém, pretože timing má rezervu, ale stále to treba brať ako riziko pri GMII RX.

---

# 3. SDC je lepšie než v eth_test_03

Toto je dôležité zlepšenie.

V `eth_test_03` boli GMII RX vstupy celé odrezané cez `set_false_path -from`. Tu už máš:

```tcl
set_input_delay -clock ETH_RXC -max 2.500 [get_ports {ETH_RXD[*]}]
set_input_delay -clock ETH_RXC -min 0.500 [get_ports {ETH_RXD[*]}]
```

a potom iba:

```tcl
set_false_path -hold -from [get_ports {ETH_RXD[*]}]
set_false_path -hold -from [get_ports {ETH_RXDV}]
set_false_path -hold -from [get_ports {ETH_RXER}]
```

To znamená:

```text
setup analýza RX vstupov ostáva aktívna,
hold je odrezaný ako známy artifact kvôli GLOBAL_SIGNAL/clock insertion.
```

To je rozumnejší kompromis než úplné vypnutie RX I/O timing analýzy.

TX výstupy sú stále false-path:

```tcl
set_false_path -to [get_ports {ETH_TXD[*]}]
set_false_path -to [get_ports {ETH_TXEN}]
set_false_path -to [get_ports {ETH_TXER}]
```

Pre diagnostický test to akceptujem, lebo `ETH_GTX_CLK` je generovaný cez `altddio_out invert_output="ON"` a fyzicky to bolo overené v eth_test_03. Dlhodobo by som ale stále chcel mať samostatný výstupný timing sign-off voči forwarded clocku.

---

# 4. Kritický návrhový problém: TX MAC negeneruje preambulu

Aktuálny `gmii_rx_mac.sv` hovorí:

```text
byte 0: SFD 0xD5
bytes 1-6: DST_MAC
...
last 4: FCS
```

Čiže RX stream zámerne obsahuje SFD.

Aktuálny `gmii_tx_mac.sv` ale robí v `ST_DATA` iba:

```systemverilog
gmii_tx_en_o <= 1'b1;
gmii_tx_er_o <= s_axis_tuser;
gmii_txd_o   <= s_axis_tdata;
```

Teda ak FIFO prvý bajt dodá `0xD5`, PHY dostane:

```text
TXEN=1, TXD=0xD5
```

bez predchádzajúceho:

```text
55 55 55 55 55 55 55
```

Pre GMII TX by MAC mal poslať:

```text
55 55 55 55 55 55 55 D5 DST SRC ETHERTYPE PAYLOAD PAD FCS
```

Aktuálne posielaš pravdepodobne:

```text
D5 DST SRC ETHERTYPE PAYLOAD FCS
```

To je neplatný Ethernet frame na linke.

## Návrh opravy

Pre tento raw loopback režim máš dve možnosti.

### Možnosť A — raw GMII loopback

RX stream nech obsahuje:

```text
SFD + frame + FCS
```

TX MAC potom musí pred stream vložiť 7 bajtov preambuly:

```text
55 55 55 55 55 55 55
```

a potom poslať stream začínajúci `D5`.

Teda TX FSM:

```text
ST_IDLE
ST_PREAMBLE  7x 0x55
ST_DATA      AXIS stream, prvý bajt očakávane 0xD5
ST_IFG
```

### Možnosť B — normálny MAC režim

RX MAC stripne:

```text
preamble/SFD
FCS
```

a AXI stream začne priamo:

```text
DST_MAC[0]
```

TX MAC potom vygeneruje:

```text
preamble + SFD + frame + FCS
```

Toto je architektonicky čistejšie a neskôr vhodnejšie pre IP/UDP stack.

Pre `eth_test_04` ako diagnostický projekt by som začal s možnosťou A, lebo chceš skúmať presný offset a nestratiť informáciu o SFD.

---

# 5. Druhý kritický problém: byte-for-byte loopback vracia zlú destination MAC

`test_loopback.py` vytvorí frame:

```text
DST = FPGA_MAC
SRC = PC_MAC
EtherType = 0x9000
payload = MAGIC + seq + body
```

FPGA ho aktuálne vráti byte-for-byte. To znamená, že echo frame má stále:

```text
DST = FPGA_MAC
SRC = PC_MAC
```

Ale prijímajúci PC očakáva, že frame na linke bude adresovaný jemu:

```text
DST = PC_MAC
SRC = FPGA_MAC
```

Ak ostane destination MAC `FPGA_MAC`, bežná NIC ho môže zahodiť na hardvérovej filtrácii, lebo nie je určený pre PC.

## Návrhové možnosti

### Možnosť A — testovať broadcast

V `test_loopback.py` posielaj:

```text
DST = FF:FF:FF:FF:FF:FF
```

FPGA ho vráti byte-for-byte ako broadcast a PC ho uvidí.

Toto je najrýchlejšie pre raw loopback test.

### Možnosť B — v FPGA pridať MAC swapper

Medzi FIFO a TX MAC vložiť jednoduchý blok:

```text
DST <= pôvodný SRC
SRC <= LOCAL_MAC alebo pôvodný DST
ostatné bajty bez zmeny
```

Potom loopback frame príde korektne späť na PC.

### Možnosť C — zapnúť promisc na PC

Napríklad cez:

```bash
sudo ip link set enp0s31f6 promisc on
```

Ale toto by som bral len ako diagnostiku, nie ako finálnu metódu.

---

# 6. Tretí kritický problém: `test_loopback.py` môže falošne PASSnúť

Skript otvorí:

```python
socket.AF_PACKET, socket.SOCK_RAW, ETH_P_ALL
```

potom spraví:

```python
sock.send(frame)
...
data = sock.recv(4096)
idx = data.find(marker)
```

Ale nekontroluje:

```text
či frame je PACKET_OUTGOING alebo PACKET_HOST
či src MAC je FPGA_MAC
či dst MAC je PC_MAC alebo broadcast
či nejde o vlastný odoslaný frame
```

Preto môže zachytiť vlastný odoslaný frame, nájsť v ňom MAGIC marker a zahlásiť PASS bez toho, aby FPGA čokoľvek vrátilo.

## Oprava testu

Použi `recvfrom()` a ignoruj outgoing pakety. Pri AF_PACKET sockaddr typicky obsahuje `pkttype`.

Princíp:

```python
data, addr = sock.recvfrom(4096)
pkttype = addr[2]

PACKET_OUTGOING = 4

if pkttype == PACKET_OUTGOING:
    continue
```

Zároveň by som kontroloval MAC adresy:

```python
dst_mac = data[0:6]
src_mac = data[6:12]

# pre MAC-swap loopback
if src_mac != fpga_mac:
    continue
if dst_mac != pc_mac and dst_mac != b'\xff'*6:
    continue
```

Pre raw byte-for-byte broadcast test:

```python
dst = ff:ff:ff:ff:ff:ff
```

a pri príjme ignorovať outgoing.

Bez tejto úpravy výsledok `loopback-test` nebude dôveryhodný.

---

# 7. Simulácia je zatiaľ neplatná

`build/sim/tb_soc_top.sv` nastavuje:

```systemverilog
ONB_BTN = '0;
```

Ale v top-e máš:

```systemverilog
assign rst_w = rst_ni && btn_i[3];
```

Teda pri `ONB_BTN='0` je `rst_w=0` stále aktívny reset.

Testbench potom po chvíli vypíše:

```text
SIM OK
```

ale design bol celý čas v resete.

## Oprava

V testbenchi má byť:

```systemverilog
ONB_BTN = 4'hF;
```

ak tlačidlá sú active-low a nestlačený stav je `1`.

A treba pridať reálny RX stimulus:

```text
RXDV=1
RXD = D5
RXD = DST...
...
RXDV=0
```

Potom kontrolovať:

```text
ETH_TXEN
ETH_TXD
teda či TX začne 55 55 55 55 55 55 55 D5 ...
```

Aktuálna simulácia neoveruje loopback vôbec.

---

# 8. RX MAC: dobré rozhodnutie, ale treba ujasniť kontrakt

`gmii_rx_mac` robí 1-cycle pipeline:

```systemverilog
rxd_q   <= gmii_rxd_i;
rx_dv_q <= gmii_rx_dv_i;

m_axis_tdata  <= rxd_q;
m_axis_tvalid <= rx_dv_q && cfg_rx_enable;
m_axis_tlast  <= rx_dv_q && !gmii_rx_dv_i;
```

Toto je rozumný spôsob, ako dostať `tlast` na posledný platný bajt.

Ale kontrakt musí byť explicitný:

```text
AXI stream z RX MAC obsahuje alebo neobsahuje SFD?
AXI stream obsahuje alebo neobsahuje FCS?
byte_cnt_q počíta SFD ako byte 0 alebo nie?
```

Aktuálne počítaš SFD ako byte 0 a Ethernet frame začína na byte 1.

To je v poriadku pre raw diagnostiku, ale nie je to klasický MAC AXI-Stream kontrakt.

Odporúčam pomenovať režim:

```systemverilog
parameter bit INCLUDE_SFD = 1'b1;
parameter bit INCLUDE_FCS = 1'b1;
```

Pre eth_test_04:

```systemverilog
INCLUDE_SFD = 1
INCLUDE_FCS = 1
```

Pre budúci normálny MAC:

```systemverilog
INCLUDE_SFD = 0
INCLUDE_FCS = 0
```

---

# 9. Async FIFO vyzerá rozumne, ale pozor na RX bez backpressure

FIFO má:

```systemverilog
wr_valid_i = rx_tvalid
wr_ready_o = nepripojené
```

Komentár:

```systemverilog
// RX MAC has no backpressure input
```

To je pri MAC RX normálne, linka sa nedá zastaviť. FIFO musí byť dostatočne veľké.

`DEPTH=2048`, šírka 10 bitov:

```text
2048 × 10 = 20,480 bitov
```

To stačí na jeden plný Ethernet frame vrátane SFD/FCS.

Pre line-rate dlhodobý loopback je dôležité:

```text
RX prijíma len SFD+frame+FCS, preambula je mimo RXDV
TX musí pridať 7 bajtov preambuly späť
TX musí držať IFG
FIFO musí absorbovať rozdiely medzi RX a TX časovaním
```

Ak pridáš TX preambulu, FIFO bude pri back-to-back trafficu stále pravdepodobne v poriadku, lebo RX má počas prijatej preambuly `RXDV=0`, takže vzniká časová rezerva.

---

# 10. Quartus warnings

Reálne dôležité:

```text
ETH_RXC not dedicated clock pin
```

Známe/akceptovateľné:

```text
ETH_MDC stuck at GND
ETH_MDIO permanently disabled output enable
UART_TX stuck at VCC
ONB_BTN[0..2] do not drive logic
```

Tieto sú očakávané v diagnostickom projekte.

Upratať by sa oplatilo:

```text
UART_RX assigned but does not exist in design
```

Nie je to funkčná chyba, ale zbytočne špiní reporty.

---

# Návrh ďalšieho postupu

## Fáza 1 — opraviť test infraštruktúru

Najprv by som opravil `test_loopback.py`, aby:

```text
1. ignoroval PACKET_OUTGOING,
2. voliteľne posielal broadcast DST,
3. vypisoval src/dst MAC zachyteného frame,
4. jasne označil offset MAGIC markeru,
5. nefiltroval iba podľa MAGIC.
```

Bez toho sa môžeme nechať oklamať vlastným odoslaným paketom.

---

## Fáza 2 — opraviť TX preambulu

Do `gmii_tx_mac` pridať režim:

```systemverilog
parameter bit INPUT_INCLUDES_SFD = 1'b1;
```

A FSM:

```text
ST_IDLE
ST_PREAMBLE
ST_DATA
ST_IFG
```

Pre raw loopback:

```text
ST_PREAMBLE: pošli 7× 0x55
ST_DATA:     pošli AXIS, prvý bajt má byť 0xD5
```

---

## Fáza 3 — rozhodnúť, či chceme raw loopback alebo MAC loopback

Pre diagnostiku RX offsetu:

```text
raw loopback:
  RX AXIS = SFD + frame + FCS
  TX = preambula + RX AXIS
```

Pre budúci stack:

```text
MAC loopback:
  RX AXIS = DST + SRC + type + payload, bez SFD/FCS
  TX = preambula + SFD + frame + novo vypočítané FCS
```

Ja by som urobil oba režimy cez parameter.

---

## Fáza 4 — pridať MAC swapper

Aby test prešiel bez promiscuous mode:

```text
prijať:
  DST=FPGA_MAC, SRC=PC_MAC

odoslať:
  DST=PC_MAC, SRC=FPGA_MAC
```

To je malý blok, ktorý prvých 12 bajtov prepíše a zvyšok pustí ďalej.

Pre raw režim so SFD na byte 0:

```text
byte 0      = SFD
bytes 1..6  = DST
bytes 7..12 = SRC
```

Swapper musí teda počítať s offsetom +1.

---

## Fáza 5 — doplniť skutočný testbench

Minimálny testbench by mal:

```text
1. pustiť reset,
2. nastaviť ONB_BTN=4'hF,
3. odoslať cez RX GMII frame:
   D5 + DST + SRC + EtherType + payload + fake/real FCS,
4. sledovať TX:
   musí sa objaviť 55 55 55 55 55 55 55 D5 ...
5. overiť, či payload/MAGIC sedí,
6. overiť tlast cez FIFO.
```

Aktuálny `tb_soc_top.sv` toto nerobí.

---

## Moja odporúčaná architektúra pre eth_test_04

Pre diskusiu by som navrhol takýto smer:

```text
gmii_rx_raw_mac
  - synchronizovaný RX vstup cez IOE FF
  - výstup: SFD + frame + FCS
  - diagnostika prvých N bajtov

async_fifo_raw
  - 10-bit: {tuser,tlast,tdata}
  - DEPTH 2048 alebo 4096

optional_l2_swapper
  - režim OFF / MAC_SWAP / BROADCAST_FORCE
  - vie pracovať s offsetom SFD

gmii_tx_raw_mac
  - vkladá 7× preamble
  - očakáva prvý AXIS byte SFD=0xD5
  - potom posiela raw stream
  - IFG 12
```

A paralelne neskôr:

```text
gmii_rx_mac_clean
  - strip SFD
  - strip/check FCS
  - AXIS začína DST_MAC[0]

gmii_tx_mac_clean
  - insert preamble/SFD
  - generate FCS
```

Takto budeš mať aj diagnostický raw nástroj, aj normálny MAC pre ďalšie vrstvy.

---

## Najdôležitejší záver

`eth_test_04` je správny krok, ale aktuálny stav ešte nie je spoľahlivý HW loopback test.

Pred ďalším HW behom by som určite opravil:

```text
1. test_loopback.py — ignorovať vlastné outgoing frames,
2. gmii_tx_mac — pridať preambulu pred SFD,
3. rozhodnúť broadcast vs MAC swap,
4. tb_soc_top — ONB_BTN=4'hF a reálny RX stimulus.
```

Až potom má zmysel interpretovať, či sa z eth_test_03 potvrdzuje 1-byte offset na RX ceste.
