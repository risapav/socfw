Áno — aktuálny stav už vyzerá ako seriózne rozpracovaná Ethernet knižnica. Toto je veľký posun oproti `eth_test_02`: už nemáš jeden monolitický `ipreceive/ipsend`, ale vrstvenú architektúru s reálne testovanými blokmi.

## Expertný verdikt

Aktuálny `eth_test_03` je v stave:

```text
MAC vrstva:        PASS
L2 parser:         PASS
L3 RX parser:      PASS
L4 UDP RX parser:  PASS
TX IPv4/UDP build: PASS
RX integračný path: PASS
Full echo path:    ešte chýba
HW top:            ešte nie je pripravený
```

To je veľmi dobrý míľnik. Najväčšie riziko už nie je „či funguje CRC alebo GMII TX“, ale **ako správne spojiť RX metadata + payload + echo app + TX builder + GMII TX**, a následne ako vyriešiť **clock-domain crossing medzi RXC a TX clockom**.

---

# 1. Čo je už dobré

## MAC vrstva je použiteľná

Máš overené:

```text
crc32_eth
gmii_tx_mac
gmii_rx_mac
stream -> tx -> rx -> stream
```

To znamená, že základný Ethernet MAC pipeline už má dôveryhodný základ.

Významné je hlavne:

```text
gmii_tx_mac:
  preambula/SFD
  Ethernet header
  padding
  FCS
  IFG

gmii_rx_mac:
  SFD sa neprepúšťa
  tlast sedí
  dátový stream sedí
```

Toto je presne základ, ktorý potrebuješ pre knižnicu.

---

## RX path je už dobre overený

`tb_rx_path` cez Verilator je veľmi dôležitý test. Overuje:

```text
GMII RX
 -> gmii_rx_mac
 -> eth_header_parser
 -> ipv4_header_parser
 -> udp_header_parser
```

A pokrýva:

```text
valid UDP HELLO
wrong dst_mac
wrong dst_ip
wrong dst_port
back-to-back valid frames
```

To je dobrý dôkaz, že RX strana parserov už má zmysluplnú kvalitu.

---

## UDP parser rieši aktuálnu FCS politiku správne

Keďže `gmii_rx_mac` zatiaľ posiela ďalej aj FCS, je dôležité, že `udp_header_parser` podľa `udp_len` forwarduje iba UDP payload a zvyšok flushuje do `s_axis_tlast`.

To je správne pre prechodný stav:

```text
RX MAC output:
  Ethernet header + IPv4 + UDP + payload + padding + FCS

UDP parser output:
  iba UDP payload
```

Tým si ochránil `udp_echo_app` pred tým, aby echo posielalo naspäť padding alebo FCS.

---

# 2. Čo ešte nie je hotové

## `ethernet_test_03_top.sv` je stále stub

Top ešte nie je cieľový systém. Vidno tam:

```systemverilog
// 4. UDP Echo App (Aplikácia) - Tu by bolo napojenie na parsery
// ... implementácia UDP parsera a Echo App ...
```

A tiež problém:

```systemverilog
.m_axis_tuser(1'b0)
```

`m_axis_tuser` je výstup z `gmii_rx_mac`, takže nemá byť pripojený na konštantu.

Správne:

```systemverilog
logic rx_axis_tuser;

.m_axis_tuser(rx_axis_tuser)
```

Top zatiaľ nepovažuj za funkčný. Máš hotové bloky, ale ešte nie systém.

---

## Chýba full echo path test

Máš RX path test a TX builder test, ale ešte nemáš test:

```text
GMII RX UDP request
 -> RX parser chain
 -> meta assembler
 -> udp_echo_app
 -> udp_ipv4_tx_builder
 -> gmii_tx_mac
 -> GMII TX response
```

Toto je teraz najdôležitejší ďalší krok.

---

## `udp_echo_app` ešte treba formálne dotiahnuť

Podľa aktuálneho kódu už latchuje `rx_meta_q`, čo je dobré. Ale ešte by som opravil alebo doplnil tieto veci:

### 1. Prijatie metadata cez handshake

V `ST_IDLE` by som explicitne písal:

```systemverilog
if (rx_meta_valid_i && rx_meta_ready_o) begin
  rx_meta_q <= rx_meta_i;
  ...
end
```

Teraz je to prakticky ekvivalentné, lebo `rx_meta_ready_o = (state_q == ST_IDLE)`, ale pre čistotu a budúcu údržbu je lepšie používať priamo handshake podmienku.

### 2. Zápis payloadu cez handshake

V `ST_RX` má byť:

```systemverilog
if (s_axis_tvalid && s_axis_tready) begin
  ...
end
```

Nie iba `s_axis_tvalid`.

Dnes to funguje, lebo `s_axis_tready` je v `ST_RX` vždy 1, ale z hľadiska stream kontraktu je lepšie písať to explicitne.

### 3. Zero-length UDP payload

`udp_header_parser` už testuje `udp_len=8`, teda nulový payload. `udp_echo_app` by mal mať jasne definované správanie pre:

```text
payload_len = 0
```

Teraz výraz typu:

```systemverilog
payload_len - 1
```

môže vytvoriť underflow. Pre UDP echo by nulový payload mal vyrobiť:

```text
tx_meta valid
žiadny payload byte
UDP length = 8
```

To si zaslúži samostatný test v `tb_udp_echo_app`.

### 4. Overflow guard

Kód síce neprepíše pamäť mimo rozsahu, ale nemá jasný stav:

```text
payload príliš dlhý -> drop/error
```

Ak payload presiahne `MAX_PAYLOAD_BYTES`, máš buď:

```text
A. dropnúť packet
B. orezať payload a nastaviť error
```

Pre knižnicu odporúčam A: drop packet + error pulse.

---

# 3. Najväčšia systémová otázka: clock domains

Toto je teraz najdôležitejšia architektonická vec.

Aktuálna architektúra má prirodzene:

```text
RX doména: eth_rx_clk_i z PHY RXC
TX doména: eth_tx_clk_i z PLL 125 MHz
```

Tieto clocky nemusia byť fázovo súvisiace. Preto nesmieš priamo prepojiť:

```text
udp_header_parser -> udp_echo_app -> udp_ipv4_tx_builder -> gmii_tx_mac
```

ak časť beží v RX clocku a časť v TX clocku.

## Odporúčané riešenie

Rozdeľ systém takto:

```text
RX clock domain:
  gmii_rx_mac
  eth_header_parser
  ipv4_header_parser
  udp_header_parser
  rx metadata assembler
  rx payload FIFO writer

CDC boundary:
  packet mailbox / async FIFO

TX clock domain:
  udp_echo_app alebo echo_tx_engine
  udp_ipv4_tx_builder
  gmii_tx_mac
```

Pre echo aplikáciu máš dve možnosti.

---

## Variant A — najjednoduchší pre bring-up

Celú echo aplikáciu spusti v RX doméne a do TX domény prenes hotový TX packet cez async FIFO.

```text
RX domain:
  parsovanie
  echo app
  udp_ipv4_tx_builder
  vytvorí celý IPv4 packet stream

async FIFO:
  IPv4 packet stream + tlast

TX domain:
  gmii_tx_mac
```

Výhoda:

```text
jednoduchší metadata handling
TX MAC dostane hotový stream
```

Nevýhoda:

```text
TX packet builder beží na RXC, nie TX clocku
```

To je pre simuláciu aj prvý HW bring-up celkom prijateľné, ak FIFO medzi builderom a TX MACom správne prenesie stream.

---

## Variant B — čistejší dlhodobý návrh

Do TX domény prenesieš:

```text
metadata FIFO
payload async FIFO
```

TX doména potom robí:

```text
udp_echo_app
udp_ipv4_tx_builder
gmii_tx_mac
```

Výhoda:

```text
TX pipeline celá beží v eth_tx_clk_i
lepšie pre timing a budúce generovanie odpovedí
```

Nevýhoda:

```text
zložitejšie CDC: metadata + payload musia zostať spárované
```

Pre `eth_test_03` by som zvolil **Variant A pre prvý FPGA bring-up**, potom neskôr Variant B ako knižničnú architektúru.

---

# 4. Najbližší technický míľnik

Tvoj ďalší míľnik by nemal byť Quartus top. Najprv musí prejsť:

```text
tb_udp_echo_full_path
```

Ale odporúčam urobiť ho v dvoch fázach.

---

## Fáza 1 — single-clock full echo path

Všetko beží na jednom `clk`.

Schéma:

```text
gmii_rx_mac
 -> eth_header_parser
 -> ipv4_header_parser
 -> udp_header_parser
 -> rx_meta_assembler
 -> udp_echo_app
 -> udp_ipv4_tx_builder
 -> gmii_tx_mac
```

Tento test má overiť čisto funkciu:

```text
UDP request HELLO
 -> UDP echo response HELLO
```

Scoreboard musí porovnať celý TX GMII frame:

```text
7x55
D5
Ethernet header
IPv4 header
UDP header
payload
padding
FCS
```

Presne byte-by-byte.

Toto je teraz najbližší povinný test.

---

## Fáza 2 — dual-clock full echo path

Až keď single-clock prejde, pridaj:

```text
RX clock = 125 MHz
TX clock = 125 MHz, iná fáza alebo mierne iná perióda v simulácii
```

Napríklad:

```text
rx_clk period = 8.000 ns
tx_clk period = 8.013 ns
```

Tým odhalíš nelegálne priame prepojenia medzi doménami.

Do tejto verzie vložíš async FIFO alebo CDC mailbox.

---

# 5. Metadata assembler

Toto je chýbajúci malý, ale dôležitý blok.

`udp_echo_app` chce:

```systemverilog
eth_pkg::udp_packet_meta_t
```

Ale metadata vznikajú na troch miestach:

```text
eth_header_parser:
  rx_src_mac_o
  rx_dst_mac_o

ipv4_header_parser:
  src_ip_o
  dst_ip_o

udp_header_parser:
  src_port_o
  dst_port_o
  payload_len_o
```

Odporúčam vytvoriť samostatný modul:

```text
udp_rx_meta_assembler.sv
```

Úloha:

```text
pri udp_header_parser.hdr_valid_o:
  zaregistruj MAC/IP/UDP metadata do udp_packet_meta_t
  vygeneruj rx_meta_valid_o
```

Rozhranie:

```systemverilog
module udp_rx_meta_assembler (
  input  wire logic clk_i,
  input  wire logic rst_ni,

  input  wire logic [47:0] eth_src_mac_i,
  input  wire logic [47:0] eth_dst_mac_i,
  input  wire logic [31:0] ip_src_i,
  input  wire logic [31:0] ip_dst_i,
  input  wire logic [15:0] udp_src_port_i,
  input  wire logic [15:0] udp_dst_port_i,
  input  wire logic [15:0] udp_payload_len_i,

  input  wire logic        udp_hdr_valid_i,

  output      logic        rx_meta_valid_o,
  input  wire logic        rx_meta_ready_i,
  output      eth_pkg::udp_packet_meta_t rx_meta_o
);
```

Dôležité: ak `rx_meta_ready_i=0`, assembler musí metadata držať. Nemôže ich stratiť.

---

# 6. FCS politika — moje odporúčanie

Aktuálne:

```text
gmii_rx_mac posiela FCS ďalej
udp_header_parser flushuje padding + FCS
```

To je funkčné pre súčasný RX path.

Dlhodobo však odporúčam:

```text
gmii_rx_mac:
  STRIP_FCS = 1
  CHECK_FCS = 0 najprv
  CHECK_FCS = 1 neskôr
```

Prečo?

Vyššie vrstvy nemajú riešiť FCS. L2/L3/L4 parsery majú vidieť čistý frame bez traileru.

Ale nemenil by som to práve teraz. Teraz máš RX path PASS. Najprv dokonči full echo path. Potom sprav refaktor FCS stripu a uprav testy.

---

# 7. Čo by som teraz nerobil

Nerobil by som ešte:

```text
Quartus top
MDIO master
ARP responder
FCS strip refaktor
RX checksum validation
UDP checksum validation
optimalizáciu timing constraints
```

To všetko je dôležité, ale teraz by to rozbilo fokus.

Momentálny cieľ je:

```text
funkčný full UDP echo path v simulácii
```

Až potom má zmysel ísť do FPGA topu.

---

# 8. Prioritný plán

## P0 — uzavrieť full echo path v jednej clock doméne

1. Pridať `udp_rx_meta_assembler.sv`.
2. Pridať `tb_udp_echo_app.sv`, ak ešte nie je.
3. Doplniť testy pre:

   ```text
   metadata latch
   zero payload
   m_axis_tready pauzy
   overflow
   ```
4. Pridať `tb_udp_echo_full_path.sv`.
5. Byte-by-byte overiť celý TX frame.

---

## P1 — dual-clock simulácia

1. Rozhodnúť CDC architektúru.
2. Pre prvý HW bring-up odporúčam:

   ```text
   RX domain vytvorí IPv4 packet stream
   async FIFO
   TX domain gmii_tx_mac
   ```
3. Pridať `tb_udp_echo_full_path_dual_clock.sv`.

---

## P2 — top-level integrácia

Až po P0/P1:

1. Dokončiť `ethernet_test_03_top.sv`.
2. Odstrániť stuby.
3. Pripojiť `eth_debug_leds`.
4. Pripojiť PHY reset extender.
5. Pripojiť `ETH_GTX_CLK = eth_tx_clk_i`.
6. MDC/MDIO zatiaľ:

   ```systemverilog
   assign eth_mdc_o = 1'b0;
   assign eth_mdio_io = 1'bz;
   ```

---

## P3 — HW bring-up

Prvé LED debug signály:

```text
LED0 heartbeat
LED1 PHY reset released
LED2 RXDV activity
LED3 UDP frame accepted
LED4 TX packet start
LED5 TXEN activity
```

Až potom skúšať Scapy/udp_echo_test z PC.

---

# 9. Krátke hodnotenie ako expert

Tento projekt je teraz v zdravej fáze. Najväčšia zmena je, že už nehádaš, či Ethernet stack funguje — máš reálne jednotkové testy a prvý RX integračný test.

Najväčšie plusy:

```text
+ MAC TX/RX je testovaný
+ L2/L3/L4 RX parsery sú testované
+ UDP parser správne oddeľuje payload od padding/FCS
+ TX IPv4/UDP builder generuje checksum
+ Verilator RX path test je veľmi dobrý krok
```

Najväčšie otvorené riziká:

```text
- full echo path ešte nie je testovaný
- metadata assembler ešte nie je explicitný blok
- clock-domain crossing ešte nie je vyriešený
- top-level je stále stub
- udp_echo_app potrebuje samostatný tvrdý TB
```

Môj odborný záver: **nechoď ešte na FPGA**. Najprv dokonči `tb_udp_echo_full_path` v single-clock režime, potom dual-clock/CDC verziu. Keď tieto dva testy prejdú, až potom má zmysel integrovať top a riešiť Quartus/HW bring-up.
