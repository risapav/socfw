Áno, dá sa testovať takmer celý reťazec až po výstupné piny, ale treba rozlíšiť tri úrovne:

```text
1. RTL simulácia po ch0/ch1/ch2 10-bit TMDS slovách
2. simulácia PHY serializéra až po hdmi_p_o[3:0]
3. reálne FPGA meranie na pinoch / interné SignalTap sondy
```

Pre tvoj aktuálny problém je práve úroveň **2 + 3** veľmi dôležitá, lebo simulácia už tvrdí, že `ch*_o` sú správne, ale monitor pri reálnych data-island packetoch padá.

---

## 1. Áno: doplniť simulačný test až po `hdmi_p_o`

Teraz veľa testov končí na úrovni:

```text
hdmi_tx_core
  → ch0/ch1/ch2 10-bit TMDS symboly
```

Treba pridať test, ktorý zapojí aj:

```text
tmds_phy_ddr_aligned
  → hdmi_p_o[3:0]
```

a v testbenchi spätne zrekonštruuje 10-bit TMDS slová z pinového serializovaného výstupu.

Cieľ:

```text
ch*_o symbol = očakávaný TMDS/TERC4 symbol
hdmi_p_o bitstream po deserializácii = rovnaký symbol
```

Tým overíš:

```text
- bit order v serializéri
- pair_cnt modulo-5 fázu
- LSB/MSB-first konvenciu
- clock lane generovanie
- či data island TERC4/guard symboly idú na piny rovnako ako video/control
```

---

## 2. Ako by vyzeral nový testbench

Navrhol by som nový test:

```text
tb_vga_hdmi_tx_phy_loopback.sv
```

alebo:

```text
tb_tmds_phy_serial_decode.sv
```

Zapojenie:

```text
video timing / test RGB
        ↓
vga_hdmi_tx
        ↓
hdmi_p_o[3:0]
        ↓
simulačný DDR deserializér
        ↓
rekonštruované 10-bit TMDS slová
        ↓
TMDS/TERC4/control checker
```

V simulácii potrebuješ generovať:

```text
pix_clk = 40 MHz modelovo
clk_x   = 5× pix_clk
```

Nemusí ísť o reálny čas, stačí správny pomer:

```systemverilog
always #5  clk_x   = ~clk_x;     // 100 MHz modelovo
always #25 pix_clk = ~pix_clk;   // 20 MHz modelovo
```

Dôležitý je pomer 5:1.

---

## 3. Čo presne dekódovať z `hdmi_p_o`

Keďže PHY je DDR, na každom `clk_x` cykle idú 2 bity z 10-bitového symbolu.

Teda pre každý kanál:

```text
clk_x cycle 0 → bit pair 0
clk_x cycle 1 → bit pair 1
clk_x cycle 2 → bit pair 2
clk_x cycle 3 → bit pair 3
clk_x cycle 4 → bit pair 4
```

Po 5 `clk_x` cykloch máš jeden 10-bit symbol.

Test musí odpovedať na otázku:

```text
Je symbol na hdmi_p_o po deserializácii rovnaký ako ch0/ch1/ch2 pred PHY?
```

Ak nie, máš problém vo PHY bit order alebo alignment.

---

## 4. Kritické: word alignment v PHY

Tvoj PHY má voľne bežiaci modulo-5 counter. Preto v simulácii musíš kontrolovať, či sa counter zarovná tak, ako očakávaš.

Pridaj do PHY debug export alebo hierarchicky sleduj:

```text
pair_cnt
sr_ch0
sr_ch1
sr_ch2
sr_clk
```

Ak nechceš meniť RTL, testbench vie čítať interné signály hierarchicky, napríklad:

```systemverilog
dut.u_phy.pair_cnt
```

Na stabilný test by som však pridal voliteľný debug výstup iba v sim konfigurácii alebo `ifdef SIM`.

---

## 5. Čo má nový PHY test odhaliť

Tento test ti povie, či problém nie je v rozdiele medzi:

```text
simulačne správne ch*_o
```

a

```text
fyzicky posielané hdmi_p_o
```

Konkrétne vie zachytiť:

```text
- TERC4 LUT je správne, ale PHY posiela bity opačne
- guard band konštanty sú v inej bitovej konvencii než video encoder
- data island symboly sú posunuté o 1 fast-clock pair
- clock channel je posunutý alebo má zlý vzor
- prvý symbol po DATA_GB je rozbitý kvôli latch timing
```

Toto presne sedí na aktuálny typ chyby:

```text
video ide
no-packet data island ide
reálny data packet spôsobí no signal
```

---

## 6. Reálne FPGA meranie: čo sa dá a nedá

### Dá sa veľmi dobre merať interne

Použi SignalTap / SignalProbe a sleduj:

```text
period
period_d1 / period_d2
packet_start
packet_pop
packet_valid
packet_hb
packet_pb[0]
formatter ch0/ch1/ch2 nibbles
TERC4 ch0/ch1/ch2 10-bit
mux ch0/ch1/ch2 10-bit
PHY pair_cnt
```

Toto je najpraktickejší HW debug. Zachytíš presný moment, keď ide GCP/AVI packet.

Odporúčam trigger:

```text
packet_start == 1
```

alebo:

```text
period == HDMI_PERIOD_DATA_PREAMBLE
```

a uložiť aspoň 100–200 pixel-clock cyklov okolo toho.

---

### Dá sa merať aj na pinoch, ale je to ťažšie

Na `PMOD_J11_HDMI_OUT[3]` clock lane by si mal vidieť približne pixel clock:

```text
800×600@60 → 40 MHz TMDS clock
```

Na data lanes ide cca:

```text
10 × 40 MHz = 400 Mbit/s
```

Keďže používaš DDR pri 200 MHz, bežný lacný logický analyzátor to spoľahlivo nedekóduje.

Na pinoch sa dá rozumne overiť:

```text
- clock lane existuje
- približná frekvencia clock lane
- či link vôbec toggluje
- či pri data islande nepríde dlhý statický úsek
```

Ale dekódovať TMDS data lanes priamo z PMOD pinov chce rýchly osciloskop / LA a dobré sondovanie. Navyše PMOD HDMI zapojenie môže byť elektricky hraničné.

---

## 7. Najlepšia praktická kombinácia

Pre teba by som odporúčal tento postup:

```text
A. Simulácia PHY loopback
B. SignalTap interný capture
C. Iba základné meranie clock lane na pinoch
```

Nie hneď externý dekódovač HDMI.

---

# Konkrétny plán

## Krok 1 — vytvor `tb_tmds_phy_loopback.sv`

Test len pre PHY:

```text
vstup:
  známe 10-bit symboly:
  CTL00
  DATA_GB
  TERC4(0)
  TERC4(1)
  VIDEO_GB
  TMDS_CLK

výstup:
  hdmi_p_o[3:0]

checker:
  deserializuje hdmi_p_o späť na 10-bit symboly
  porovná s očakávaním
```

Tento test najprv nepoužívaj celý HDMI core. Len PHY.

---

## Krok 2 — vytvor `tb_vga_hdmi_tx_pin_decode.sv`

Potom testuj celý reťazec:

```text
vga_hdmi_tx
  → hdmi_p_o
  → sim deserializer
  → TMDS/TERC4 decode
```

Scenáre:

```text
DATA=0 AUDIO=0
T1 DEBUG_ISLAND_PHASES=1
T2 DEBUG_ISLAND_PHASES=2
T3 DEBUG_ISLAND_PHASES=3
2B GCP-only
2C AVI-only
```

---

## Krok 3 — SignalTap capture na FPGA

Pridaj interné sondy:

```text
period
packet_start
packet_pop
packet_hb[0..2]
di_ch0/1/2
terc4_ch0/1/2
mux ch0/1/2
phy pair_cnt
```

Trigger:

```text
packet_start rising edge
```

Pre GCP-only by si mal vidieť:

```text
HB = 00 00 00
PB = all zero
BCH header = 0e
BCH subpacket = f5
```

Ak interné signály sedia, ale monitor padá, potom problém je medzi mux výstupom a fyzickým HDMI linkom:

```text
PHY bit order
PHY alignment
IO electrical layer
monitor kompatibilita
```

---

## Krok 4 — T2/T3 HW test

Stále je veľmi dôležité pokračovať v:

```text
T2: preamble + guard bands
T3: preamble + guard + 1 payload symbol
```

Ak T2 zlyhá, nemusíš riešiť BCH/ECC. Je to guard/preamble/PHY.
Ak T2 prejde a T3 zlyhá, je to TERC4/payload/PHY.
Ak T3 prejde a full packet zlyhá, je to dĺžka payloadu/ECC/obsah/sink.

---

## Odpoveď na otázku

Áno, komplet reťazec sa dá testovať aj s výstupom na reálne piny, ale odporúčam to robiť v dvoch krokoch:

```text
1. simulovaný pin-level loopback:
   hdmi_p_o → deserializer → checker

2. reálny FPGA debug:
   SignalTap interné signály + základné meranie TMDS clock lane
```

Tým dostaneš odpoveď, či je chyba ešte v digitálnom RTL reťazci, alebo až v PHY/pinoch/monitore.
