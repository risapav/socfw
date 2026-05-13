Tento status sedí s tým, čo vidno v poslednej sade kódu. Vývoj sa posunul z „DVI-like HDMI výstupu“ na **prvý reálny HDMI data-island pokus s AVI InfoFrame**. To je veľký míľnik.

Moje hodnotenie aktuálneho stavu:

```text
DVI/TMDS video path:        veľmi blízko použiteľnému HW testu
AVI InfoFrame data island:  architektonicky zapojený, analyticky overený
Plný HDMI packet systém:    ešte nie, zatiaľ jeden AVI packet
Audio:                      ešte nezačaté
```

Najdôležitejšie je, že už máte správne hlavné vrstvy:

```text
video timing
  ↓
hdmi_tx_core
  ↓
period scheduler
  ↓
video/control/data-island symbol generation
  ↓
channel mux
  ↓
word-aligned TMDS PHY
```

To je správny smer.

---

## Čo by som teraz považoval za „hotové“

### 1. Architektonická separácia

Toto je už dobré:

```text
video_timing_generator
vga_hdmi_tx wrapper
hdmi_tx_core
data_island_formatter
tmds_phy_ddr_aligned
```

Už nie je premiešaný VGA timing, HDMI symbolika a PHY v jednom bloku. To je zásadné.

### 2. Data-island infraštruktúra

Pridaním:

```text
hdmi_bch_ecc
data_island_formatter
AVI infoframe path
TERC4 ×3
```

ste spravili najťažší skok od DVI k HDMI. Ak BCH testy sedia pre header a subpackety, je to veľmi dobrý signál.

### 3. Scheduler už myslí v HDMI periódach

Stavy:

```text
CONTROL
DATA_PREAMBLE
DATA_GB_LEAD
DATA_PAYLOAD
DATA_GB_TRAIL
VIDEO_PREAMBLE
VIDEO_GB
VIDEO
```

s `blank_remaining >= 54` sú správna filozofia. Toto je veľký rozdiel oproti pôvodnému „ak DE, posielaj video, inak control“.

---

## Čo by som ešte nepovažoval za plný HDMI

Plný HDMI ešte nie je hotový, lebo zatiaľ chýba hlavne packetový subsystém a audio:

```text
GCP
packet arbiter
ACR N/CTS
Audio InfoFrame
Audio Sample Packet
audio FIFO / I2S alebo PCM vstup
EDID/DDC
```

Aktuálne je to skôr:

```text
HDMI video + jeden AVI InfoFrame cez data island
```

To je ale správny medzistupeň.

---

## Priorita 1: HW test je správne ďalší krok

Súhlasím s tvojím poradím. Teraz už nemá veľký zmysel iba ďalej refaktorovať naslepo. Treba overiť fyzickú realitu:

```text
1. Zobrazí sa obraz?
2. Drží link stabilne?
3. Nerozpadáva sa TMDS word alignment?
4. Vidí monitor signál ako HDMI, nie iba DVI?
5. Vidí analyzer AVI InfoFrame?
```

Ak obraz nejde, najpravdepodobnejšie príčiny budú:

```text
- PHY bit order
- pair_cnt fáza
- PLL/reset timing
- TMDS channel order B/G/R/CLK
- DDR output polarity
- HDMI PMOD pin mapping
```

Ak obraz ide, ale InfoFrame nie, hľadal by som:

```text
- data island preamble CTL hodnoty
- guard band hodnoty
- BCH/ECC bit order
- data_island_formatter bit mapping
- latencia DATA_PAYLOAD vs TERC4 výstup
```

---

## Priorita 2: dynamický data guard band CH0

Súhlasím, že toto treba opraviť skôr než pridávať ďalšie pakety.

Aktuálny fixný:

```text
DATA_GB ch0 = 0100110011
```

môže fungovať, ale nie je čistý. Správny dizajn by mal mať v `hdmi_channel_mux` buď priamo `hsync_i/vsync_i`, alebo lepšie pripravený symbol z core:

```systemverilog
input tmds_word_t data_gb_ch0_i;
```

Ja by som preferoval druhú možnosť:

```text
guard_band_generator
  ↓
hdmi_channel_mux
```

Tým mux zostane iba muxom a nebude robiť protokolové výpočty.

Napríklad:

```systemverilog
logic [3:0] data_gb_ch0_nibble;
tmds_word_t data_gb_ch0;

assign data_gb_ch0_nibble = {1'b1, vsync_aligned, hsync_aligned, 1'b1};

terc4_encoder u_terc4_data_gb_ch0 (
  .clk_i    (pix_clk_i),
  .rst_ni   (rst_ni),
  .nibble_i (data_gb_ch0_nibble),
  .tmds_o   (data_gb_ch0)
);
```

Pozor: ak použiješ registrovaný `terc4_encoder`, musíš opäť zarovnať latenciu. Pre guard band by možno bolo jednoduchšie mať **kombinačnú TERC4 funkciu** v package alebo samostatný `terc4_lut_comb`, aby guard symbol nevnášal ďalší takt.

---

## Priorita 3: SDC constraints pre PHY

Toto je kritické. Ak teraz používaš:

```tcl
set_clock_groups -asynchronous
```

medzi pixel a 5× clock, nástroj vôbec neoveruje cestu:

```text
TMDS word register in pix_clk
    ↓
sampled by clk_x domain in PHY
```

To môže na stole „náhodou“ fungovať, ale nie je to sign-off.

Lepší smer je definovať generated clocks a multicycle path medzi pixel a 5× clock. Tvoj návrh:

```tcl
set_multicycle_path -setup -from clk_pixel -to clk_pixel5x -num_cycles 5
set_multicycle_path -hold  -from clk_pixel -to clk_pixel5x -num_cycles 4
```

je filozoficky správny, ale treba ho napísať konkrétne podľa názvov clockov v Quartuse a skontrolovať cez timing report, že sa vzťahuje len na relevantné registre.

Cieľ:

```text
- nie async clock group medzi pixel a 5×
- generated clock relationship známy
- multicycle len na pix_clk → clk_x capture v PHY
- reset synchronizovaný
```

---

## Priorita 4: ponechať `packet_scheduler.sv` ako legacy

Súhlasím, že pre aktuálny AVI-only prístup ho nepotrebuješ.

Ja by som ho teraz urobil explicitne:

```text
legacy/packet_scheduler_byte_stream.sv
```

alebo odstránil z build setu. Znížiš riziko, že sa omylom niekde znovu použije.

Pre plný HDMI bude lepší nový blok:

```text
hdmi_packet_arbiter
```

ktorý pracuje s celými packetmi, nie bajtovým streamom.

---

## Ďalší vývoj k plnému HDMI

Tvoje poradie je dobré. Ja by som ho mierne upravil takto:

### Krok 1 — HW bring-up bez ďalšieho RTL rastu

Najprv:

```text
ENABLE_DATA_ISLAND=0
```

overiť čistý DVI obraz.

Potom:

```text
ENABLE_DATA_ISLAND=1
```

overiť obraz + AVI data island.

Dôvod: ak sa s data islands rozbije obraz, vieš oddeliť PHY/video problém od HDMI packet problému.

---

### Krok 2 — opraviť spec-clean drobnosti

Pred ďalšími paketmi:

```text
- dynamický data GB ch0
- presne overené CTL/preamble hodnoty
- latency audit scheduler → formatter → TERC4 → mux
- SDC multicycle
```

Tu by som pridal jednoduchý interný debug výstup alebo SignalTap signály:

```text
period
packet_start
packet_pop
formatter_active
formatter_symbol_index
di_ch0/ch1/ch2
blank_remaining
de
```

Na HW to veľmi pomôže.

---

### Krok 3 — GCP pred AVI

Ďalší logický HDMI packet je GCP.

Neimplementoval by som ho cez starý scheduler, ale ako nový packet source:

```text
gcp_packet_builder
avi_packet_builder
    ↓
hdmi_packet_arbiter
    ↓
data_island_formatter
```

Prvá verzia arbitra môže byť úplne jednoduchá:

```text
po frame_start:
  slot 1: GCP
  slot 2: AVI
potom nič
```

Teda žiadna zložitá fronta ešte netreba.

---

### Krok 4 — packet arbiter

Navrhoval by som typ rozhrania:

```systemverilog
typedef struct packed {
  logic [23:0]  hb;        // {HB2, HB1, HB0}
  logic [223:0] pb;        // 28 bytes packed
  logic         valid;
} hdmi_packet_packed_t;
```

Prečo packed vector a nie `logic [7:0] pb [0:27]`?
Lebo packed typy sa ľahšie prenášajú cez porty, debugujú a syntetizujú konzistentne medzi nástrojmi.

Potom utility funkcie:

```systemverilog
function automatic logic [7:0] get_pb(
  input logic [223:0] pb,
  input int idx
);
  return pb[8*idx +: 8];
endfunction
```

---

### Krok 5 — ACR pred audio sample packetmi

Pre audio by som nezačal audio sample packetizerom. Začal by som:

```text
ACR packet
```

Lebo bez ACR nemusí prijímač správne rekonštruovať audio clock.

Prvá verzia:

```text
48 kHz audio
N = 6144
CTS podľa pixel clocku / TMDS clocku
```

Pre 48 kHz a základné TMDS režimy vieš ísť tabuľkou. Neskôr sa dá spraviť generátor.

---

### Krok 6 — Audio InfoFrame

Potom Audio InfoFrame:

```text
2ch LPCM
speaker allocation default
sample frequency podľa cfg
sample size podľa cfg
```

Ten už tvoj `infoframe_builder` čiastočne podporuje.

---

### Krok 7 — Audio sample packetizer

Až potom:

```text
PCM/I2S input
audio FIFO
audio sample packetizer
```

Prvý test by som nerobil cez I2S, ale interným generátorom:

```text
1 kHz square/sine tone
48 kHz
2ch
16-bit alebo 24-bit
```

Tým odstrániš ďalšiu clock doménu z prvého audio bring-upu.

---

## Čo by som doplnil do testov

Okrem HW testu by som pridal minimálne tieto simulácie:

```text
1. tmds_video_encoder_ref_tb
2. data_island_formatter_tb
3. hdmi_period_scheduler_tb
4. hdmi_tx_core_avi_tb
5. tmds_phy_ddr_aligned bit-order tb
```

Najdôležitejší je `hdmi_tx_core_avi_tb`, ktorý overí časovanie:

```text
control preamble
data guard
32 payload symbolov
data guard
control
video preamble
video guard
video
```

V tomto teste by som assertoval:

```text
DATA_PAYLOAD sa nikdy neprekrýva s DE
packet_pop má presne 32 pulzov
VIDEO_GB má presne 2 cykly
VIDEO_PREAMBLE má presne 8 cyklov
```

---

## Moje odporúčané najbližšie tri úlohy

### 1. HW bring-up matrix

Otestovať štyri konfigurácie:

```text
A: ENABLE_DATA_ISLAND=0, 640×480/800×600
B: ENABLE_DATA_ISLAND=1, AVI enabled
C: data island vypnutý, ale video preamble/GB zapnuté
D: data island zapnutý, ale iba počas vblank
```

Toto ti povie, ktorá vrstva prípadne zlyháva.

### 2. Dynamický CH0 data guard band

Opraviť, aby ste sa zbavili známej nekompatibility.

### 3. Packet arbiter skeleton

Nie audio ešte. Len:

```text
GCP + AVI
```

raz za frame.

---

## Finálne hodnotenie

Aktuálny stav `vga_test_05` by som označil takto:

```text
DVI video TX:                takmer pripravené na HW validáciu
HDMI AVI data island:        prvá implementácia pripravená na HW/simulačné overenie
Plné HDMI packet vrstvy:     začaté, ešte bez arbitra
Audio:                       zatiaľ návrhová fáza
PHY timing sign-off:         treba SDC a HW overenie
```

Najväčší posun je, že už máte **skutočný data-island formatter s BCH/ECC**, nie iba symbolickú TERC4 cestu. To je podstatný míľnik. Ďalší míľnik je: **monitor alebo analyzer potvrdí AVI InfoFrame**. Potom má zmysel pridávať GCP a audio.
