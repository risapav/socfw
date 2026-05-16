Potvrdené: podľa nahraného `TEST_MATRIX.md` je stav teraz jednoznačný:

```text
#1  DATA=0 AUDIO=0              PASS
#2A DATA=1 AUDIO=0 GCP=0 AVI=0  PASS
#2B DATA=1 AUDIO=0 GCP=1 AVI=0  FAIL / no signal
```

Matica to už správne zapisuje: 2A prešiel a 2B zlyhal ako „no signal; GCP-only fails while 2A passes“.

## Čo som overil v nahratých súboroch

Nahratý `soc_top.sv` naozaj zodpovedá 2B:

```systemverilog
.ENABLE_ACR_PACKET(0),
.ENABLE_AUDIO(0),
.ENABLE_AUDIO_INFOFRAME(0),
.ENABLE_AUDIO_SAMPLE(0),
.ENABLE_AVI_PACKET(0),
.ENABLE_DATA_ISLAND(1),
.ENABLE_GCP_PACKET(1)
```

Čiže HW test bol skutočne:

```text
DATA=1
AUDIO=0
GCP=1
AVI=0
```

Nahratý `hdmi_period_scheduler.sv` má lookahead model:

```systemverilog
ST_DATA_GUARD_LEAD:
  packet_pop_o = 1'b1;

ST_DATA_PAYLOAD:
  packet_pop_o = (sym_cnt > 6'd1);
```

Čiže simulačný fix typu „31 popov, symbol0 nie je duplikovaný“ je v tomto súbore prítomný.

V `gcp_packet_builder.sv` je GCP konzervatívny:

```systemverilog
hb_o = '{default: 8'h00};
pb_o = '{default: 8'h00};
pb_o[0] = {avmute_i, clear_avmute_i, 2'b00, 4'b0000};
```

a v `hdmi_tx_core.sv` je pripojený ako:

```systemverilog
.avmute_i(1'b0),
.clear_avmute_i(1'b0)
```

Teda reálny GCP packet je:

```text
HB = 00 00 00
PB = all zero
```

To je najjednoduchší možný GCP.

---

# Záver

Keďže 2A PASS a 2B FAIL, a GCP je all-zero, problém pravdepodobne **nie je AVMUTE ani color-depth bit v GCP payload-e**.

Teraz ostávajú hlavne tieto možnosti:

```text
1. all-zero GCP packet ako taký je v data islande zakódovaný nesprávne,
2. BCH/ECC pre GCP sa v end-to-end ceste líši od očakávania,
3. data island guard/preamble symboly sú simulačne kontrolované, ale fyzicky monitor stále odmieta prvý data packet,
4. GCP sa posiela v nevhodnom čase voči frame/blankingu,
5. konkrétny monitor je citlivý na GCP pri PC/VESA režime 800×600 s VIC=0/no AVI,
6. single-ended PMOD HDMI zapojenie má hraničnú integritu a data island vzory s GCP zhoršia lock.
```

Najdôležitejšie: **GCP-only je prvý zlyhávajúci prípad.** Audio ani AVI zatiaľ netreba riešiť.

---

# Odporúčaný ďalší test: 2B-rate-limit

Skús neposielať GCP každý frame. Pošli GCP iba raz za N frameov.

Pridaj dočasný parameter napríklad:

```systemverilog
parameter int GCP_FRAME_PERIOD = 1
```

a povoľ GCP iba keď:

```systemverilog
(frame_counter % GCP_FRAME_PERIOD) == 0
```

Testy:

```text
2B-rare-1:  GCP raz po resete
2B-rare-60: GCP raz za 60 frameov
2B-normal:  GCP každý frame
```

Interpretácia:

```text
rare GCP PASS, every-frame FAIL:
  problém je opakovanie/umiestnenie GCP alebo reakcia sinku na častý GCP.

rare GCP FAIL:
  problém je samotný GCP data island.
```

---

# Druhý veľmi dôležitý test: 2C AVI-only

Aj keď 2B zlyhal, urob 2C:

```text
DATA=1 AUDIO=0 GCP=0 AVI=1
```

Prečo? Lebo odlíši, či monitor odmieta **každý reálny data island packet**, alebo špecificky GCP.

Interpretácia:

```text
2C PASS:
  problém je špecificky GCP packet alebo GCP timing.

2C FAIL:
  problém je všeobecná data-island packet cesta, ktorú 2A neaktivuje.
```

Toto je teraz veľmi dôležité. Ak 2C tiež zlyhá, nehľadaj už GCP obsah — chyba je spoločná packet path.

---

# Tretí test: namiesto GCP poslať AVI ako prvý packet po frame_start

Ak 2C PASS samostatne, ale 2B FAIL, skús potvrdiť, či problém je „packet type 0x00“ alebo stav `ARB_GCP`.

Dočasný test:

```text
GCP state enabled, ale hb/pb pripoj na AVI builder
```

Neodporúčam to ako finálne riešenie, ale diagnosticky to povie:

```text
zlyháva packet type/content GCP
alebo zlyháva časovanie prvého packetu vo frame
```

Ak „AVI v GCP slote“ prejde, problém je GCP obsah/type.
Ak zlyhá, problém je časovanie prvého data islandu po frame_start.

---

# Čo doplniť do simulácie

Sim teraz prechádza, ale HW nie. Preto doplň test, ktorý overí **presný prvý data island po frame_start**:

```text
frame_start cycle
→ počet cyklov do DATA_PREAMBLE
→ pozícia v riadku / blank_remaining
→ či je to počas vertical blank alebo active frame hblank
→ hsync/vsync hodnoty počas GCP
```

Do logu vypíš pri každom `packet_start`:

```systemverilog
$display("PKT start: cy=%0d x=%0d y=%0d blank_rem=%0d hb=%02x %02x %02x",
         sim_cycle, x, y, blank_remaining, hb[0], hb[1], hb[2]);
```

Ak prvý GCP ide v úplne inom mieste než očakávaš, sink ho môže odmietnuť.

---

# Praktický ďalší krok

Urob tieto dva HW testy v poradí:

```text
1. 2C: DATA=1 AUDIO=0 GCP=0 AVI=1
2. 2B-rare: DATA=1 AUDIO=0 GCP=1 AVI=0, ale GCP iba raz za 60 frameov alebo raz po resete
```

Ak 2C zlyhá tiež, zameriame sa na spoločnú data-island packet cestu.
Ak 2C prejde, zameriame sa výlučne na GCP typ/timing.
