Máš pravdu. Moje nekonzistentné kontroly ti zbytočne skomplikovali debug. Pri RTL vývoji, kde jeden cyklus pipeline rozhoduje o funkčnosti HDMI, je takáto chyba drahá. Ďalej by som postupoval prísnejšie a viac test-driven, aby sa už neopieralo o ručné interpretácie.

## Odporúčaný ďalší postup pre vývoj full HDMI

Teraz by som vývoj rozdelil na dve paralelné línie:

```text
A. stabilizácia a verifikácia existujúceho HDMI TX jadra
B. postupné doplnenie full HDMI funkcií
```

Najbližšie by som **nepridával nové funkcie**, kým nebude úplne uzavretý problém:

```text
ENABLE_AUDIO=1 + ENABLE_DATA_ISLAND=1
```

---

# 1. Zafixuj aktuálnu verziu ako „known baseline“

Najprv si vytvor čistý baseline commit.

Odporúčaný názov:

```text
hdmi: baseline after data-island scheduler refactor
```

Do commitu zahrň:

```text
rtl/hdmi/*.sv
sim/*.sv
sim/Makefile
sim/logs/regression_full.log
CHANGELOG.md
```

Do `CHANGELOG.md` alebo `docs/TEST_MATRIX.md` zapíš:

```text
Simulation baseline:
- tb_hdmi_bch_ecc PASS
- tb_terc4_encoder PASS
- tb_data_island_formatter PASS
- tb_hdmi_period_scheduler PASS
- tb_acr_packet_builder PASS
- tb_audio_sample_packet_builder PASS
- tb_hdmi_tx_core_32x10 PASS

Hardware baseline:
- AUDIO=0 DATA=0 : PASS
- AUDIO=0 DATA=1 : PASS
- AUDIO=1 DATA=0 : PASS
- AUDIO=1 DATA=1 : FAIL / monitor sleep alebo black screen
```

Toto bude referenčný bod, ku ktorému sa vieš vrátiť.

---

# 2. Uzavri data-island výstupný test na `ch*_o`

Toto je najdôležitejší ďalší krok.

Už máš unit testy pre:

```text
formatter
scheduler
TERC4
core period timing
```

Teraz potrebuješ test, ktorý spojí celú cestu:

```text
packet builder
 → packet arbiter
 → scheduler packet_pop
 → data_island_formatter
 → TERC4 encoder
 → channel mux
 → ch0/ch1/ch2
```

Cieľ testu:

```text
Počas DATA_PAYLOAD musí ch0/ch1/ch2 niesť presne:
TERC4(symbol0), TERC4(symbol1), ..., TERC4(symbol31)
```

Nie iba:

```text
DATA_PAYLOAD trvá 32 cyklov
```

Dĺžka 32 nestačí. Obsah musí sedieť.

## Konkrétna úloha

Rozšír `tb_hdmi_tx_core_32x10.sv` o:

```text
period_d2
payload_output_idx
terc4_ref()
expected ch0/ch1/ch2 payload nibbles
asserty na ch*_o počas output-stage DATA_PAYLOAD
```

Ak tento test prejde, budeš mať konečne dôkaz, že scheduler/formatter/TERC4/mux sú zarovnané.

---

# 3. Pridaj core-level scenáre pre jednotlivé packet typy

Nespoliehaj sa už len na `ENABLE_AUDIO=1`. Rozbi to na presnú maticu.

V `hdmi_tx_core` / `vga_hdmi_tx` používaj parametre:

```systemverilog
ENABLE_ACR_PACKET
ENABLE_AUDIO_INFOFRAME
ENABLE_AUDIO_SAMPLE
```

Potom vytvor simulačné targety:

```text
tx_core_32x10_avi_only
tx_core_32x10_acr_only
tx_core_32x10_audio_if_only
tx_core_32x10_sample_only
tx_core_32x10_acr_audio_if
tx_core_32x10_full_audio
```

Každý test musí overiť:

```text
1. packet sa vložil do data islandu
2. dĺžky periód sedia
3. payload obsah na ch*_o sedí
4. video sa po packete obnoví
5. žiadny DATA_PAYLOAD nezasiahne do active video
```

Toto je priamo relevantné k problému s monitorom.

---

# 4. Potvrď ACR layout raz a navždy

ACR je kritický. Tu nesmie byť neistota medzi:

```text
MSB-first layout
LSB-first layout
```

Sprav jeden dokument:

```text
docs/HDMI_PACKET_LAYOUT.md
```

A doň zapíš presne:

```text
ACR packet:
HB0 = ...
HB1 = ...
HB2 = ...

PB0 = ...
PB1 = ...
PB2 = ...
PB3 = ...
PB4 = ...
PB5 = ...
PB6 = ...
```

Potom musia byť konzistentné tri veci:

```text
acr_packet_builder.sv
tb_acr_packet_builder.sv
docs/HDMI_PACKET_LAYOUT.md
```

Ak sa tieto tri rozídu, regression má zlyhať.

---

# 5. Hardware test rob až po prechode sim matice

Až keď prejdú tieto sim testy:

```text
AVI only
ACR only
Audio IF only
Sample only
Full audio
```

potom choď na monitor.

Hardware testuj v tomto poradí:

```text
1. DATA=0 AUDIO=0
   očakávanie: obraz

2. DATA=1 AUDIO=0
   očakávanie: obraz

3. DATA=1 AUDIO=1, ACR only
   očakávanie: obraz, bez audia

4. DATA=1 AUDIO=1, AudioIF only
   očakávanie: obraz, bez audia

5. DATA=1 AUDIO=1, Sample only
   očakávanie: obraz alebo ticho, ale nie sleep

6. DATA=1 AUDIO=1, ACR + AudioIF
   očakávanie: obraz

7. DATA=1 AUDIO=1, full audio
   očakávanie: obraz, prípadne audio
```

Výsledky zapisuj do `docs/TEST_MATRIX.md`.

---

# 6. Nepúšťaj zatiaľ audio sample packet na plnú rýchlosť

Aj keď packet formát bude správny, audio sample tok bez FIFO je stále slabé miesto.

Pre prvý hardware test odporúčam dočasný debug režim:

```text
audio sample packet maximálne raz za N riadkov
alebo raz za frame
```

Cieľom nie je hneď počuť správny tón. Cieľom je overiť:

```text
monitor nezaspí pri audio sample packete
```

Až potom rieš skutočný audio rate.

---

# 7. Zaviesť audio FIFO ako ďalší architektonický krok

Aktuálny test source je dobrý na bring-up, ale full HDMI audio by malo vyzerať takto:

```text
audio source / I2S receiver
 → audio sample FIFO
 → audio packetizer
 → packet arbiter
 → data island formatter
```

Bez FIFO bude audio sample rate viazaný na to, kedy scheduler dovolí vložiť packet. To je krehké.

Odporúčané ďalšie moduly:

```text
hdmi_audio_fifo.sv
i2s_rx.sv alebo audio_test_tone_gen.sv
audio_packet_scheduler.sv
```

---

# 8. Dokonči riadenie InfoFrame a packet konfigurácie

Až po stabilnom audio/data-island bring-upe dokonči:

```text
ENABLE_AVI
ENABLE_SPD
ENABLE_AUDIO_IF
info_cfg_i
```

Teraz by som zjednotil názvy:

Buď používať:

```systemverilog
ENABLE_AUDIO_INFOFRAME
```

alebo:

```systemverilog
ENABLE_AUDIO_IF
```

Nie oboje naraz, ak jeden iba mätie.

Odporúčanie:

```systemverilog
parameter bit ENABLE_AUDIO_INFOFRAME = 1;
```

a `ENABLE_AUDIO_IF` odstrániť.

Pre `info_cfg_i`:

```systemverilog
valid_avi      = ENABLE_AVI && info_cfg_i.send_avi;
valid_audio_if = ENABLE_AUDIO_INFOFRAME && info_cfg_i.send_audio && enable_audio_i;
valid_spd      = ENABLE_SPD && info_cfg_i.send_spd;
```

Ale pozor: ak `vga_hdmi_tx` stále pripája `.info_cfg_i('0)`, tak po zavedení tejto logiky sa InfoFrame vypnú. Preto treba vo wrapperi vytvoriť default config.

---

# 9. PHY nechaj ako technický dlh, ale zapíš ho

Keďže video už ide, PHY teraz nie je prvý problém. Ale do `docs/KNOWN_ISSUES.md` zapíš:

```text
TMDS PHY uses free-running 5x pair counter.
No explicit pix_clk/clk_x word alignment strobe yet.
Works on current board/mode, but should be hardened later.
```

Neskôr doplniť:

```text
separate reset synchronizer for clk_x domain
explicit word_start_x_i
or vendor serializer primitive
```

---

# 10. Zaviesť prísny pracovný postup pre ďalšie refaktory

Aby sa nestalo to, čo teraz, odporúčam:

## Každý refaktor = jeden malý cieľ

Nie:

```text
opraviť HDMI audio
```

Ale:

```text
opraviť TERC4 latency
```

alebo:

```text
zmeniť packet_pop na lookahead model
```

alebo:

```text
pridať core-level payload check
```

## Každý cieľ musí mať test

Príklad:

```text
Zmena:
  packet_pop_o lookahead

Test:
  tb_hdmi_period_scheduler packet_pop count = 31
  tb_hdmi_tx_core_32x10 ch*_o payload symbols 0..31
```

## Každá zmena musí mať commit

Formát:

```text
hdmi: fix data island payload advance timing

- packet_pop_o now advances formatter during guard lead exit
- payload stage no longer pops 32 times
- fixes symbol0 duplication and symbol31 loss
- verified by tb_hdmi_period_scheduler and tb_hdmi_tx_core_32x10
```

---

# Prioritný plán odteraz

## Krok 1 — uzavrieť simulačný dôkaz data island výstupu

```text
tb_hdmi_tx_core_32x10:
  overiť finálne ch*_o počas DATA_PAYLOAD
```

Bez toho nechoď na monitor.

## Krok 2 — pridať audio packet scenáre do simulácie

```text
ACR only
Audio IF only
Sample only
Full audio
```

## Krok 3 — spustiť `make report`

Výstup uložiť:

```text
sim/logs/regression_full.log
```

## Krok 4 — hardware matrix

Presne zapísať výsledky.

## Krok 5 — ak full audio stále zaspáva

Potom už budeš vedieť, ktorý konkrétny packet zlyháva:

```text
ACR?
Audio IF?
Sample?
kombinácia?
```

A budeš opravovať konkrétny builder alebo formatter, nie naslepo.

---

# Môj odporúčaný roadmap pre full HDMI

## Milestone 1: DVI video stable

Stav: prakticky hotové.

```text
TMDS video
control periods
PHY output
800x600 monitor image
```

## Milestone 2: HDMI data island stable

Rozpracované.

Musí prejsť:

```text
AVI/GCP data island
payload content check
no video overlap
monitor nezaspí
```

## Milestone 3: HDMI audio packets stable

Najbližší cieľ.

Musí prejsť:

```text
ACR only
Audio InfoFrame only
Audio Sample only
full combination
```

## Milestone 4: Audio architecture

Doplniť:

```text
audio FIFO
I2S receiver alebo stabilný test tone source
periodický ACR scheduling
```

## Milestone 5: Full HDMI polish

Doplniť:

```text
AVI config
SPD InfoFrame
proper info_cfg_i
VIC/aspect/quantization
clean packet queue
```

## Milestone 6: PHY hardening

Doplniť:

```text
clk_x reset synchronizer
word alignment
vendor DDR/serializer primitive
constraints
```

---

## Najbližší konkrétny task

Najbližšia vec, ktorú by som urobil, je:

```text
Rozšíriť tb_hdmi_tx_core_32x10 tak, aby počas DATA_PAYLOAD kontroloval finálne ch0/ch1/ch2 proti TERC4 referencii.
```

Toto je najväčšia medzera medzi „simulácia prešla“ a „monitor bude akceptovať HDMI data island“.

Keď toto prejde, budeš mať oveľa pevnejšiu pôdu pre ďalší hardware test.
