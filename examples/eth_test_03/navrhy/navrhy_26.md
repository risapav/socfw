Áno, reset cez `btn_i[3]` beriem ako zámerný a vyradzujem ho ako podozrivú príčinu. Rovnako IP/interface už neberiem ako root cause. Pozrel som sa bližšie na **Quartus reporty, pin report, SDC a RTL8211EG PDF** z toho istého ZIP-u:

```text
eth_test_03.zip SHA-256:
57f575b26d5adf22ba9f6631e39e2267cd0b88f2f9ae9bb92c775ce487ef3528
```

## Krátky verdikt

V reportoch nevidím klasický fatálny pin problém typu zlý pin, duplicita, nepriradený GMII signál alebo zlý I/O štandard. Ale vidím **tri vážne timing/sign-off problémy**, ktoré môžu priamo vysvetľovať správanie v HW:

1. **GMII RX/TX I/O timing je v SDC prakticky odpojený cez `set_false_path`.**
   Teda Quartus síce hlási PASS, ale negarantuje reálne GMII časovanie voči RTL8211EG.

2. **`ETH_RXC` je na pine `R19`, ktorý Quartus nepovažuje za dedicated clock pin.**
   Fitter síce povýšil `ETH_RXC` na global clock `GCLK6`, ale priamo hlási:

   ```text
   Pin ETH_RXC~input drives global or regional clock Global Clock,
   but is not placed in a dedicated clock pin position
   ```

   Pri 125 MHz GMII RX je toto veľmi citlivé, hlavne keď RXD/RXDV prichádzajú source-synchronous voči `RXC`.

3. **Aktuálny STA v ZIP-e už nemá veľkú rezervu.**
   `ETH_RXC` setup slack je iba:

   ```text
   Slow 1200mV 85C Setup ETH_RXC: +0.012 ns
   ```

   Toto je prakticky nulová rezerva. Status súbor spomína starší stav s väčším slackom, ale aktuálny `output_files/soc_top.sta.summary` v ZIP-e hovorí `+0.012 ns`.

---

# 1. Pin assignment: nevidím chybu typu zle expandovaný vektor

Z `soc_top.pin` a `build/hal/board.tcl`:

```text
ETH_RXC      R19   input   Bank 5
ETH_RXDV     K21   input   Bank 6
ETH_RXER     R21   input   Bank 5

ETH_RXD[0]   K22   input   Bank 6
ETH_RXD[1]   L21   input   Bank 6
ETH_RXD[2]   L22   input   Bank 6
ETH_RXD[3]   M21   input   Bank 5
ETH_RXD[4]   N21   input   Bank 5
ETH_RXD[5]   N22   input   Bank 5
ETH_RXD[6]   P21   input   Bank 5
ETH_RXD[7]   P22   input   Bank 5

ETH_GTX_CLK  U22   output  Bank 5
ETH_TXEN     V21   output  Bank 5
ETH_TXER     AA18  output  Bank 4

ETH_TXD[0]   V22   output  Bank 5
ETH_TXD[1]   W22   output  Bank 5
ETH_TXD[2]   Y21   output  Bank 5
ETH_TXD[3]   Y22   output  Bank 5
ETH_TXD[4]   AA20  output  Bank 4
ETH_TXD[5]   AB19  output  Bank 4
ETH_TXD[6]   AA19  output  Bank 4
ETH_TXD[7]   AB18  output  Bank 4
```

`ETH_TXD[*]` a `ETH_RXD[*]` sú v tomto ZIP-e expandované korektne. Duplicitné pin assignmenty som nenašiel.

I/O štandard je všade:

```text
3.3-V LVTTL
```

A podľa RTL8211EG dokumentácie je pre RTL8211EG-VB GMII podporované 3.3 V alebo 2.5 V rozhranie. Takže z pohľadu Quartusu sú I/O banky a I/O štandard konzistentné.

---

# 2. RTL8211EG GMII timing z dokumentácie

V PDF `doc/RTL8211E-VB-CG_11.PDF`, Table 58 — GMII Timing Parameters:

```text
RxCLK cycle time:              typ 8 ns
GTxCLK/RxCLK high time:        min 2.5 ns
GTxCLK/RxCLK low time:         min 2.5 ns
GTxCLK/RxCLK rise/fall time:   max 1 ns

RxD/RxDV/RxER setup to RxCLK ↑: 2.5 ns min
RxD/RxDV/RxER hold  from RxCLK ↑: 0.5 ns min

TxD/TxEN setup to GTxCLK ↑:    2 ns min
TxD/TxEN hold  from GTxCLK ↑:  0 ns min
```

Toto znamená:

```text
RX: PHY dáva RXD/RXDV voči RXC, FPGA musí zachytiť na RXC.
TX: FPGA dáva TXD/TXEN voči GTX_CLK, PHY zachytáva na rising edge GTX_CLK.
```

V aktuálnom RTL je TX filozofia správna:

```systemverilog
altddio_out invert_output("ON")
```

čiže `ETH_GTX_CLK` je posunutý o ~4 ns voči `eth_tx_clk_i`, aby PHY videl TXD stabilné pred sampling edge. To sedí s požiadavkou RTL8211EG: TX setup min 2 ns.

---

# 3. Najväčší problém: SDC najprv nastaví GMII delaye, potom ich zruší

V `build/timing/soc_top.sdc` máš najprv toto:

```tcl
set_input_delay -clock ETH_RXC -max 2.500 [get_ports {ETH_RXD[*]}]
set_input_delay -clock ETH_RXC -min 0.500 [get_ports {ETH_RXD[*]}]

set_input_delay -clock ETH_RXC -max 2.500 [get_ports {ETH_RXDV}]
set_input_delay -clock ETH_RXC -min 0.500 [get_ports {ETH_RXDV}]

set_input_delay -clock ETH_RXC -max 2.500 [get_ports {ETH_RXER}]
set_input_delay -clock ETH_RXC -min 0.500 [get_ports {ETH_RXER}]
```

Ale neskôr ich celé zrušíš:

```tcl
set_false_path -from [get_ports {ETH_RXD[*]}]
set_false_path -from [get_ports {ETH_RXDV}]
set_false_path -from [get_ports {ETH_RXER}]
```

Podobne TX:

```tcl
set_false_path -to [get_ports {ETH_GTX_CLK}]
set_false_path -to [get_ports {ETH_TXD[*]}]
set_false_path -to [get_ports {ETH_TXEN}]
set_false_path -to [get_ports {ETH_TXER}]
```

Toto je podľa mňa teraz hlavná metodická chyba.

Nie nutne okamžitý RTL bug, ale znamená to:

```text
Quartus timing PASS != GMII I/O timing PASS
```

Aktuálny STA kontroluje interné registre v doménach `ETH_RXC`, `ETH_TX_CLK`, `SYS_CLK`, ale nekontroluje, či:

```text
PHY -> FPGA RXD/RXDV/RXER spĺňa setup/hold voči ETH_RXC
FPGA -> PHY TXD/TXEN spĺňa setup/hold voči ETH_GTX_CLK
```

Takže kompilácia môže byť zelená, ale GMII môže byť na hrane alebo mimo špecifikácie.

---

# 4. `ETH_RXC` na nededikovanom clock pine je vážny kandidát

Fitter report:

```text
ETH_RXC: PIN_R19
Global Resource Used: Global Clock
Global Line Name: GCLK6
Fan-Out: 1613
```

A zároveň:

```text
Info (176342): Pin ETH_RXC~input drives global or regional clock Global Clock,
but is not placed in a dedicated clock pin position
```

Toto je dôležité. Pri GMII RX má PHY veľmi úzke okno:

```text
RXD setup: 2.5 ns pred RXC ↑
RXD hold:  0.5 ns po RXC ↑
```

Ak `RXC` ide cez nevhodnú/nededikovanú cestu na global clock, môže byť capture edge vo FPGA posunutý voči dátam. Fitter sa to snaží riešiť, dokonca report ukazuje:

```text
Estimated Delay Added for Hold Timing Summary:
ETH_RXC -> ETH_RXC : 2.8 ns
```

A na vstupoch vidno delay:

```text
ETH_RXD[*] / ETH_RXDV : 2640 ps
```

Čiže Quartus už do tejto domény pridáva oneskorenia na hold. To nie je samo o sebe zlé, ale pri GMII 125 MHz to znamená, že RX časovanie je citlivé. A keď sú externé RX paths následne `false_path`, nevieš, či je to skutočne správne voči RTL8211EG.

Toto by mohlo vysvetliť napríklad stav:

```text
udp_tvalid = 1
udp_tlast  = 0
```

Ak sa občas zle vzorkuje UDP length alebo alignment, parser môže začať payload, ale nikdy nedosiahne očakávaný payload end pred `s_axis_tlast`.

---

# 5. Aktuálny STA je horší než uvádza status

`ETH_TEST_03_STATUS.md` hovorí o výrazne lepších slackoch v niektorých fázach, ale aktuálne reporty v ZIP-e hovoria:

```text
Slow 85C setup:
ETH_RXC     +0.012 ns
ETH_TX_CLK  +0.729 ns
SYS_CLK     +5.052 ns
```

Fmax:

```text
ETH_RXC     125.19 MHz
ETH_TX_CLK  137.53 MHz
SYS_CLK      66.90 MHz
```

Najhorší `ETH_RXC` path:

```text
udp_echo_app:u_echo|rx_meta_q.payload_len[0]
    -> meta_wr_data_q[...]
Data Delay: 7.897 ns
Slack:      0.012 ns
```

Toto je interný RX-domain path, nie pin path. Čiže ešte pred riešením externého GMII RX sign-offu máš vnútri RX domény takmer nulovú rezervu.

## Odporúčanie

Rozbi tento path pridaním registra medzi `udp_echo_app` / `tx_meta` a `meta_wr_data_q`.

Aktuálne máš:

```systemverilog
if (txb_fire_w && txb_tlast) begin
  meta_wr_data_q   <= {meta_latch_dst_q, meta_latch_src_q};
  commit_pending_q <= 1'b1;
end
```

A `meta_latch_*` sa plnia pri:

```systemverilog
if (tx_meta_valid && tx_meta_ready) begin
  meta_latch_dst_q <= tx_meta.dst_mac;
  meta_latch_src_q <= tx_meta.src_mac;
end
```

Ale TimeQuest stále vidí dlhý path z `rx_meta_q.payload_len` do `meta_wr_data_q`. To znamená, že optimalizácia/packed struct/logika okolo `tx_meta` stále vytvára závislosť na `payload_len`.

Spravil by som explicitný registrovaný TX meta stage:

```systemverilog
logic [47:0] tx_meta_dst_mac_q;
logic [47:0] tx_meta_src_mac_q;
logic        tx_meta_latched_q;

always_ff @(posedge eth_rx_clk_i or negedge rst_w) begin
  if (!rst_w) begin
    tx_meta_dst_mac_q <= '0;
    tx_meta_src_mac_q <= '0;
    tx_meta_latched_q <= 1'b0;
  end else begin
    if (tx_meta_valid && tx_meta_ready) begin
      tx_meta_dst_mac_q <= tx_meta.dst_mac;
      tx_meta_src_mac_q <= tx_meta.src_mac;
      tx_meta_latched_q <= 1'b1;
    end

    if (txb_fire_w && txb_tlast) begin
      tx_meta_latched_q <= 1'b0;
    end
  end
end
```

A `meta_wr_data_q` plniť už len z týchto čistých registrov:

```systemverilog
if (txb_fire_w && txb_tlast) begin
  meta_wr_data_q   <= {tx_meta_dst_mac_q, tx_meta_src_mac_q};
  commit_pending_q <= 1'b1;
end
```

Cieľ: najhorší `ETH_RXC` slack dostať z `+0.012 ns` aspoň nad `+1 ns`.

---

# 6. Fast I/O register assignmenty

Dobrá správa: kľúčové GMII I/O registre sú naozaj zabalené do I/O.

Fitter ukazuje:

```text
Packed Fast Input Register:
ETH_RXD[0..7]
ETH_RXDV
```

A:

```text
Packed Fast Output Register:
ETH_TXD[0..7]
ETH_TXEN
```

Ignorované assignmenty sú:

```text
Fast Input Register  -> ETH_RXER  ignored
Fast Output Register -> ETH_TXER  ignored
UART_RX location     ignored, lebo UART_RX neexistuje v design
```

Toto nie je hlavný problém:

```text
ETH_RXER nepoužívaš v logike
ETH_TXER je stále 0
UART_RX v top-e nie je
```

Odporúčam ale upratať to, aby reporty boli čistejšie:

```tcl
# odstrániť alebo negenerovať, ak signál nie je použitý:
set_instance_assignment -name FAST_INPUT_REGISTER ON -to ETH_RXER
set_instance_assignment -name FAST_OUTPUT_REGISTER ON -to ETH_TXER
set_location_assignment PIN_J2 -to UART_RX
```

Nie preto, že to opraví HW, ale aby si neprehliadol budúce reálne warnings.

---

# 7. MDIO/MDC warning je očakávaný, ale diagnosticky ťa obmedzuje

Report:

```text
Pin ETH_MDC is stuck at GND
Pin ETH_MDIO has permanently disabled output enable
```

RTL:

```systemverilog
assign eth_mdc_o   = 1'b0;
assign eth_mdio_io = 1'bz;
```

To je v súlade s tým, že MDIO zatiaľ nemáš. Nie je to dôvod, prečo nefunguje echo, ak PHY je správne strapnutý a link je 1 Gbps.

Ale praktický problém je, že bez MDIO nevieš potvrdiť:

```text
PHY mode: GMII vs RGMII
speed resolved: 1000M
duplex
link status
PHY ID
strap register
```

RTL8211EG dokumentácia ukazuje, že `Mode` strap musí byť:

```text
Mode = 0 -> MII/GMII
Mode = 1 -> RGMII
```

A `SELRGV`:

```text
1 -> 3.3V RGMII/GMII
0 -> 2.5V RGMII/GMII
```

Keďže máš 1 Gbps link a RX/TX beacony už podľa statusu boli viditeľné, PHY pravdepodobne beží správne. Ale MDIO master by som pridal ako ďalší diagnostický modul.

---

# 8. Najpravdepodobnejšie vysvetlenie aktuálneho HW problému

Keď beriem do úvahy:

```text
btn reset OK
IP/interface OK
link 1Gbps OK
beacon TX bol v minulosti viditeľný
aktuálny problém je echo
J11 predtým ukázal udp_tvalid=1, ale udp_tlast=0
```

tak poradie podozrivých je teraz:

## 1. RX GMII sampling / externý timing nie je garantovaný

Najmä kvôli kombinácii:

```text
ETH_RXC nie je dedicated clock pin
RXC ide cez global clock
RXD/RXDV sú cez false_path
SDC nekontroluje reálny RTL8211EG RX setup/hold
```

Toto môže spôsobiť nespoľahlivé alebo posunuté bajty. Potom parser môže vidieť časť UDP payloadu, ale nedosiahnuť `udp_tlast`.

## 2. Interný ETH_RXC timing je na hrane

`+0.012 ns` je príliš málo. Aj keď STA formálne prejde, v reálnom HW môže zlyhať pri teplote/napätí/fitter variabilite.

## 3. Echo app / UDP parser stav pri krátkych payload frame

Pre tvoje testy 2B, 5B, 16B by to nemalo byť zásadné, ale pozrel by som sa špeciálne na handshake medzi:

```text
udp_header_parser hdr_pre_valid
udp_rx_meta_assembler valid_q
udp_echo_app ST_IDLE -> ST_RX
udp_tlast
```

Dôležité: `udp_echo_app` v `ST_IDLE` zachytí prvý payload byte, ale `s_axis_tlast` v tom istom cykle ignoruje. Pre payload 1B by to bol bug. Tvoje testy začínajú 2B, takže to nevysvetľuje všetko, ale opravil by som to preventívne.

---

# 9. Čo by som zmenil ako prvé

## A. Dočasný build: zapni RX clock/timing diagnostiku

Vytvor test build, kde neriešiš echo, ale overíš čistý RX byte stream cez UART tap alebo J10.

Zachytiť pre prvý UDP frame:

```text
Ethernet dst MAC
Ethernet src MAC
Ethertype
IPv4 protocol
UDP length
UDP dst port
prvé payload bajty
```

Ak pri opakovanom teste nie je UDP length stále rovnaký a správny, je to RX sampling/timing.

---

## B. Odstráň `set_false_path` z GMII RX vstupov

Dočasne vyhoď:

```tcl
set_false_path -from [get_ports {ETH_RXD[*]}]
set_false_path -from [get_ports {ETH_RXDV}]
set_false_path -from [get_ports {ETH_RXER}]
```

Potom nechaj Quartus reálne zahlásiť, čo si myslí o RX input timing. Možno dostaneš porušenia, ale to je presne informácia, ktorú teraz potrebuješ.

---

## C. Odstráň `set_false_path` z GMII TX výstupov a sprav separátny TX sign-off

Dočasne vyhoď:

```tcl
set_false_path -to [get_ports {ETH_TXD[*]}]
set_false_path -to [get_ports {ETH_TXEN}]
set_false_path -to [get_ports {ETH_TXER}]
set_false_path -to [get_ports {ETH_GTX_CLK}]
```

Potom nastav výstupné constrainty voči forwarded `ETH_GTX_CLK`. Aj keby boli najprv nepresné, je lepšie vidieť report než GMII úplne schovať.

---

## D. Rozbi interný `ETH_RXC` critical path

Toto by som spravil hneď, nezávisle od I/O:

```text
rx_meta_q.payload_len[0] -> meta_wr_data_q
slack +0.012 ns
```

To je príliš blízko. Pridaj registrovaný stage pre TX meta MAC polia a zníž závislosti z packed structu.

---

## E. Pridaj MDIO read-only diagnostiku

Minimálne:

```text
PHY ID1 / ID2
BMSR link status
BMCR speed/duplex/autoneg
PHY specific status register
strap/mode status, ak dostupné
```

Nemusíš hneď robiť plný driver. Stačí po resete prečítať registre a vyviesť stav na UART/J10/J11.

---

# 10. Konkrétny záver k pinom/timingu

Pin assignment ako taký vyzerá správne.

Ale timing reporty hovoria:

```text
Kompilácia PASS nie je dôkaz, že GMII funguje korektne.
GMII I/O časovanie je v SDC odrezané false-pathmi.
ETH_RXC je na nededikovanom clock pine.
Aktuálny interný ETH_RXC slack je iba +0.012 ns.
```

Najsilnejší technický kandidát na HW problém je preto:

```text
RX GMII timing/sign-off problém alebo interný ETH_RXC path na hrane,
nie zlá IP, nie btn reset, nie duplicitné ETH_TXD piny.
```

Ak beacon v aktuálnej Faze 4K stále vidíš, TX fyzika je v poriadku. Potom sa sústreď na `udp_tlast=0`: buď je prijatý UDP length/alignment zlý kvôli RX sampling/timingu, alebo je chyba v RX parser handshake okolo začiatku payloadu.
