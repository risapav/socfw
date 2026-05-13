Nižšie je technická analýza podľa nahratých `.sv` súborov a návrh ďalšieho postupu pre plný HDMI TX modul.

## Stav architektúry

Projekt už má dobrý modulárny základ:

* `vga_hdmi_tx.sv` — top bridge RGB565/VGA → HDMI PHY.
* `hdmi_tx_core.sv` — hlavný pixel-clock HDMI core.
* `tmds_video_encoder.sv`, `tmds_control_encoder.sv`, `terc4_encoder.sv` — základné TMDS/TERC4 kódovanie.
* `hdmi_period_scheduler.sv` — prepínanie medzi control/video/data-island periódami.
* `infoframe_builder.sv`, `gcp_packet_builder.sv`, `acr_packet_builder.sv`, `audio_sample_packet_builder.sv` — packet builders.
* `data_island_formatter.sv` + `hdmi_bch_ecc.sv` — data island layout + BCH/ECC.
* `tmds_phy_ddr_aligned.sv` — 5× pixel-clock DDR serializer.

To je už viac než jednoduchý DVI výstup. Kód smeruje k HDMI TX s InfoFrame, ACR a audio sample packetmi. Najväčšie riziká sú však v časovaní, synchronizácii serializera, packet schedulingu a nedokončenom riadení konfiguračných parametrov.

---

## Najdôležitejšie zistenia

### 1. Viaceré vstupy/parametre sú zatiaľ nepoužité alebo len čiastočne použité

V `hdmi_tx_core.sv` sú definované:

```systemverilog
ENABLE_AVI
ENABLE_SPD
ENABLE_AUDIO_IF
info_cfg_i
frame_start_i
line_start_i
```

ale prakticky neovládajú správanie packetov. `ENABLE_AVI`, `ENABLE_SPD`, `ENABLE_AUDIO_IF` a `info_cfg_i` sú momentálne mŕtva konfigurácia. `frame_start_i` a `line_start_i` sa registrujú, ale nepoužívajú.

Dôsledok: modul sa tvári konfigurovateľne, ale reálne arbiter posiela pevne danú sekvenciu `GCP → AVI → ACR → Audio IF` podľa `vsync` hrany a nie podľa explicitného `frame_start_i` alebo `info_cfg_i`.

**Odporúčanie:**
Pre full HDMI treba prejsť z `vsync_i` edge detekcie na explicitné `frame_start_i`. Vsync polarita môže byť aktívna low/high podľa módu a spoliehať sa na rising edge `vsync` je krehké.

---

### 2. `vblank_i` je privedený do scheduleru, ale scheduler ho nepoužíva

`hdmi_period_scheduler.sv` má vstup:

```systemverilog
input logic vblank_i
```

ale v FSM sa nepoužíva. Data islands sa spúšťajú len pri `hblank_i`.

To môže fungovať iba vtedy, ak tvoj timing generator nastavuje `hblank_i` aj počas vertikálneho blankingu po riadkoch. Ak `hblank_i` znamená len horizontálny blank v aktívnych riadkoch, data islands sa počas vertical blank nebudú vkladať.

**Odporúčanie:**
Definovať presnú semantiku:

```text
hblank_i = mimo aktívnej časti riadku
vblank_i = mimo aktívnej časti frame
blanking_i = !de_i
```

a v scheduleri používať buď `blanking_i`, alebo `hblank_i || vblank_i` podľa toho, kde chceš povoliť data islands. Pre InfoFrame a audio je lepšie mať riadenie cez `blanking_i` + rozpočet `blank_remaining_i`.

---

### 3. Packet arbiter je zatiaľ príliš jednoduchý pre spoľahlivé audio

`hdmi_packet_arbiter.sv` posiela raz za frame sekvenciu GCP/AVI/ACR/Audio IF a v idle stave posiela audio sample packet, keď `valid_sample_i`.

Problém je hlavne audio:

* `hdmi_audio_test_src.sv` vytvorí 4 sample páry a čaká na `consume_i`.
* Ak scheduler dlho nevloží data island, nové audio vzorky sa neakumulujú.
* To znamená, že reálna audio frekvencia bude závisieť od toho, ako často sa packet spotrebuje.
* Pre skutočné HDMI audio treba FIFO/queue, nie iba 4-sample latch.

**Odporúčanie:**
Pridať audio FIFO:

```text
audio sample generator / I2S receiver
        ↓
small FIFO alebo packet FIFO
        ↓
audio sample packetizer
        ↓
packet arbiter
        ↓
data island formatter
```

ACR packet by sa tiež nemal posielať iba raz za frame. Treba ho plánovať periodicky podľa pixel clock/audio clock pravidiel.

---

### 4. PHY serializer má kritické riziko zarovnania 5× clocku voči pixel clocku

`tmds_phy_ddr_aligned.sv` predpokladá, že `clk_x_i = 5 × pixel clock` a že `pair_cnt` je správne fázovo zarovnaný k pixelovej hranici. Kód ale nedostáva explicitný `pix_clk_i`, `pixel_strobe`, ani reset-fázovaciu informáciu.

Aktuálne:

```systemverilog
pair_cnt <= (pair_cnt == 3'd4) ? 3'd0 : pair_cnt + 3'd1;
```

Tento counter vo fast clock doméne beží voľne. Ak reset nie je deterministicky zarovnaný k pixel clocku, môže sa 10-bitové slovo načítať s ľubovoľným offsetom. HDMI receiver potom nemusí vidieť správne TMDS symbol boundaries.

**Toto je jedna z najvyšších priorít.**

**Odporúčanie:**

* Generovať `pix_clk` aj `clk_x` z jedného PLL.
* Reset uvoľniť až po `pll_locked`.
* Zabezpečiť deterministické zarovnanie `pair_cnt == 0` k pixelovej hrane.
* Ideálne pridať do PHY explicitný `load_strobe_x5`, ktorý označí začiatok nového TMDS wordu v 5× doméne.
* Alebo urobiť serializer priamo v vendor primitive/ALTDDIO/OSERDES štýle s garantovaným word alignmentom.

---

### 5. Top-level má iba `hdmi_p_o`, nie plný diferenciálny HDMI výstup

`vga_hdmi_tx.sv` exportuje:

```systemverilog
output logic [3:0] hdmi_p_o
```

Pre reálny HDMI konektor potrebuješ podľa FPGA/boardu:

```text
TMDS_DATA0_P/N
TMDS_DATA1_P/N
TMDS_DATA2_P/N
TMDS_CLK_P/N
```

Ak board používa externý odporový/level-shift obvod alebo len pseudo-differential zapojenie, môže to byť zámer. Ale pre „plný HDMI modul“ by som top-level rozšíril minimálne na:

```systemverilog
output logic [3:0] hdmi_p_o,
output logic [3:0] hdmi_n_o
```

alebo použil priamo vendor-specific differential output primitives.

---

### 6. `data_island_formatter.sv` má internú nejednoznačnosť pri HSYNC/VSYNC bitoch

V komentári je uvedené:

```systemverilog
input hsync_i // passed to ch0[1]
input vsync_i // passed to ch0[0]
```

ale výstup je:

```systemverilog
assign ch0_o = {parity, hdr_bit, vsync_i, hsync_i};
```

To znamená:

```text
ch0_o[1] = vsync_i
ch0_o[0] = hsync_i
```

Čiže komentár a implementácia nesedia. To ešte nemusí znamenať, že implementácia je zlá, ale pre HDMI data island je presné poradie control bitov dôležité.

**Odporúčanie:**
Urobiť samostatný golden-vector test pre data island channel 0 mapping:

```text
HSYNC/VSYNC combinations:
00, 01, 10, 11
```

a overiť proti očakávaným TERC4 symbolom pre guard band aj payload.

---

### 7. TMDS video encoder má netriviálnu polaritu, treba golden testy

`tmds_video_encoder.sv` na konci robí:

```systemverilog
tmds_o <= ~word;
```

Komentár hovorí, že interná konvencia je invertovaná. To môže byť správne, ale je to presne typ veci, ktorý sa musí overiť golden vektormi, nie iba vizuálne na monitore.

**Odporúčanie:**
Pripraviť testbench pre:

* `tmds_control_encoder`
* `terc4_encoder`
* `tmds_video_encoder`
* `hdmi_bch_ecc`
* `infoframe_builder`
* `data_island_formatter`

a porovnať výstupy s referenčným Python/C++ modelom.

---

## Navrhovaný vývojový postup

### Fáza 1 — Stabilný DVI-compatible video výstup

Cieľ: spoľahlivý obraz bez data islands.

Nastavenie:

```systemverilog
ENABLE_DATA_ISLAND = 0
ENABLE_AUDIO       = 0
```

Overiť:

1. TMDS control symbols počas blankingu.
2. TMDS video symbols počas `de_i`.
3. Správne oneskorenie DE/HS/VS voči RGB.
4. Stabilný serializer word alignment.
5. Správny TMDS clock channel.
6. Výstup na monitore pri jednom jednoduchom móde, napríklad 640×480p60 alebo 800×600p60.

Priorita: najprv vyriešiť PHY alignment. Bez toho bude všetko ostatné náhodne zlyhávať.

---

### Fáza 2 — Simulačný HDMI monitor

Pred ďalším hardvérovým ladením odporúčam napísať jednoduchý SystemVerilog/Python monitor, ktorý z `ch0_o/ch1_o/ch2_o` kontroluje periódy.

Minimálne asserty:

```systemverilog
// Data payload nikdy nesmie zasiahnuť do active video.
assert (!(period_o == HDMI_PERIOD_DATA_PAYLOAD && de_aligned));

// Video guard band musí trvať presne 2 symboly.
assert_video_gb_len_2;

// Data preamble musí trvať presne 8 symbolov.
assert_data_preamble_len_8;

// Data payload musí trvať presne 32 symbolov.
assert_data_payload_len_32;

// Pred VIDEO musí byť VIDEO_PREAMBLE + VIDEO_GB.
assert_video_has_preamble;
```

Toto ti veľmi rýchlo odhalí chyby v `blank_remaining_i`, pipeline delay a scheduleri.

---

### Fáza 3 — Dokončiť riadenie packetov

Upraviť `hdmi_packet_arbiter.sv` a `hdmi_tx_core.sv` tak, aby packet scheduling používal:

```systemverilog
frame_start_i
line_start_i
info_cfg_i.send_avi
info_cfg_i.send_audio
info_cfg_i.send_spd
ENABLE_AVI
ENABLE_SPD
ENABLE_AUDIO_IF
```

Odporúčaná politika:

```text
Na frame_start:
  queue AVI InfoFrame, ak enabled
  queue Audio InfoFrame, ak audio enabled
  queue SPD InfoFrame, ak enabled
  queue GCP podľa potreby

Počas frame:
  periodicky queue ACR
  queue audio sample packets podľa FIFO levelu
```

Namiesto FSM typu `ARB_GCP → ARB_AVI → ...` by som prešiel na malú packet queue:

```systemverilog
typedef enum logic [2:0] {
  PKT_NONE,
  PKT_GCP,
  PKT_AVI,
  PKT_SPD,
  PKT_AUDIO_IF,
  PKT_ACR,
  PKT_AUDIO_SAMPLE
} packet_type_e;
```

Potom arbiter len vyberie najvyššiu prioritu, ktorú scheduler vie poslať.

---

### Fáza 4 — Data island bring-up bez audia

Najprv zapnúť iba AVI InfoFrame:

```systemverilog
ENABLE_DATA_ISLAND = 1
ENABLE_AUDIO       = 0
```

Cieľ:

* monitor stále ukazuje obraz,
* sink rozpozná HDMI mód, nie iba DVI,
* AVI InfoFrame má správny checksum,
* data islandy neprekrývajú video.

Najskôr neposielať audio. Audio je ďalšia úroveň komplikácie.

---

### Fáza 5 — GCP a InfoFrame konfigurácia

Doplniť:

* reálne použitie `info_cfg_i`,
* správny `VIC`,
* aspect ratio,
* RGB quantization range,
* prípadne SPD InfoFrame.

V `vga_hdmi_tx.sv` teraz ide do core:

```systemverilog
.info_cfg_i('0)
.vic_code_i(8'd0)
.aspect_ratio_i(ASPECT_RATIO_4_3)
.quant_range_i(QUANT_RANGE_FULL)
```

Pre full HDMI by top-level mal mať parametre alebo vstupy:

```systemverilog
parameter logic [7:0] VIC_CODE = ...
parameter aspect_ratio_e ASPECT = ...
parameter quant_range_e QUANT = ...
```

alebo prijímať štruktúru `hdmi_info_cfg_t`.

---

### Fáza 6 — Audio až po stabilnom video + InfoFrame

Audio postupne:

1. Audio InfoFrame bez sample packetov.
2. ACR packet periodicky.
3. Test tone cez interný generator.
4. Nahradiť test tone skutočným audio vstupom, napríklad I2S.
5. Pridať audio FIFO.
6. Kontrolovať sample rate drift.

Aktuálny `hdmi_audio_test_src.sv` je dobrý na prvý bring-up, ale nie je vhodný ako finálne audio riešenie, pretože nemá FIFO a sample rate je viazaný na úspešné spotrebovanie packetov.

---

## Konkrétne úpravy, ktoré by som spravil ako prvé

### A. Opraviť frame trigger v packet arbiteri

Namiesto:

```systemverilog
input logic vsync_i;
wire w_vsync_rise = vsync_i && !r_vsync_prev;
```

použiť:

```systemverilog
input logic frame_start_i;
```

a v core pripojiť oneskorený/aligned `frame_start_r`.

---

### B. Zapracovať enable/config signály

V `hdmi_tx_core.sv`:

```systemverilog
.valid_audio_if_i(enable_audio_i && ENABLE_AUDIO_IF && info_cfg_i.send_audio)
```

AVI:

```systemverilog
send_avi = ENABLE_AVI && info_cfg_i.send_avi;
```

SPD:

```systemverilog
send_spd = ENABLE_SPD && info_cfg_i.send_spd;
```

Teraz sa SPD builder síce vie vytvoriť cez `infoframe_builder`, ale nie je vôbec integrovaný do `hdmi_tx_core`.

---

### C. Pridať PHY word alignment mechanizmus

Návrh interface:

```systemverilog
module tmds_phy_ddr_aligned (
  input logic pix_clk_i,
  input logic clk_x_i,
  input logic rst_ni,
  ...
);
```

alebo:

```systemverilog
input logic word_start_x_i
```

kde `word_start_x_i` je pulz v 5× clock doméne raz za pixel. Bez deterministického word-start signálu je serializer rizikový.

---

### D. Napísať minimálny HDMI packet testbench

Testovať postupnosť:

```text
DATA_PREAMBLE: 8
DATA_GB_LEAD: 2
DATA_PAYLOAD: 32
DATA_GB_TRAIL: 2
VIDEO_PREAMBLE: 8
VIDEO_GB: 2
VIDEO: active pixels
```

a pre každý packet overiť:

```text
HB0..HB2
PB0..PB27
BCH header ECC
BCH subpacket ECC
TERC4 výstupy
```

---

## Prioritný roadmap

### Sprint 1: DVI stabilita

* Golden testy pre TMDS control/video.
* Fix/overenie serializer alignmentu.
* Simulačný monitor pre DE/HS/VS/RGB pipeline.
* Hardvérový test s farebnými pruhmi.

### Sprint 2: HDMI bez audia

* Zapnúť `ENABLE_DATA_ISLAND`.
* Použiť `frame_start_i`, nie `vsync` edge.
* Posielať AVI InfoFrame raz za frame.
* Overiť checksum a data island timing.
* Overiť, že monitor rozpozná HDMI a správny mód.

### Sprint 3: Packet systém

* Nahradiť pevný arbiter malou packet queue/prioritizáciou.
* Pridať SPD/GCP gating.
* Použiť `info_cfg_i`.
* Zaviesť asserty na packet start/pop.

### Sprint 4: Audio

* Periodický ACR scheduler.
* Audio InfoFrame.
* Audio sample FIFO.
* Test tone.
* Potom I2S vstup.

### Sprint 5: FPGA/board integrácia

* PLL constraints.
* CDC/multicycle constraints medzi pixel a 5× doménou.
* TMDS IO standard/output buffer.
* Prípadne diferenciálne `P/N` výstupy.
* Test s viacerými rozlíšeniami.

---

## Najväčšie riziká podľa priority

1. **PHY word alignment medzi pixel clock a 5× clock.**
2. **Packet trigger cez `vsync` namiesto `frame_start_i`.**
3. **Nepoužité enable/config signály.**
4. **Audio bez FIFO a bez robustného ACR schedulingu.**
5. **Neoverené bitové poradie v data island formatteri.**
6. **Neoverená polarita/konvencia TMDS video encoderu.**
7. **Top-level nemá plné diferenciálne HDMI výstupy.**

---

## Záver

Kód je dobrý základ pre vlastný HDMI TX. Ako DVI/video jadro je štruktúra rozumná. Pre „plný HDMI modul“ by som ale teraz nešiel hneď ďalej pridávaním funkcií. Najprv by som stabilizoval tri veci:

1. **Serializer/PHY alignment.**
2. **Simulačné overenie TMDS + data island timing.**
3. **Packet scheduling cez `frame_start_i` a reálne config enable signály.**

Až potom by som zapínal audio. Audio bez FIFO a bez periodického ACR bude pravdepodobne najťažšie odladiť na reálnom monitore/TV.
