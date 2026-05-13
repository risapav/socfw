Áno, v tejto verzii ste vo vývoji HDMI postúpili citeľne dopredu. Už to nie je iba DVI-like TMDS jadro; pribudli prvé stavebné bloky pre skutočný HDMI data-island prenos:

```text
+ hdmi_bch_ecc.sv
+ data_island_formatter.sv
+ rozšírený video_timing_generator s hblank/vblank/blank_remaining
+ word-aligned TMDS PHY
+ oddelené video/control/TERC4 encodery
```

Ale aktuálny stav ešte stále nie je plne štandardný HDMI s InfoFrame/audio. Najväčší rozdiel je tento:

```text
data_island_formatter už existuje,
ale hdmi_tx_core ho zatiaľ nepoužíva.
```

Čiže ste sa posunuli z architektonickej kostry k potrebným blokom, ale integrácia HDMI data island vrstvy ešte nie je dokončená.

---

# 1. Aktuálny stav podľa míľnikov

## Míľnik A — DVI-compatible video

Toto je už veľmi blízko správnemu stavu.

Máte:

```text
RGB/video timing
    ↓
hdmi_tx_core
    ↓
TMDS video/control encoder
    ↓
channel mux
    ↓
tmds_phy_ddr_aligned
```

Dôležité zlepšenia:

```text
+ tmds_video_encoder má de_i
+ running disparity sa resetuje mimo active video
+ tmds_control_encoder je samostatný
+ hdmi_channel_mux je registrovaný
+ tmds_phy_ddr_aligned nahradil nevyhovujúci CDC serializer
```

Toto je správny smer pre stabilný obraz.

Zostáva overiť:

```text
- TMDS video encoder proti referenčnému modelu
- reálne časovanie PHY vo FPGA
- fázové zarovnanie pix_clk_i a clk_x_i
- reset po PLL lock
```

Hodnotenie:

```text
DVI-compatible HDMI video: približne 80–90 % architektonicky hotové
```

---

## Míľnik B — video timing infraštruktúra

`video_timing_generator.sv` je teraz veľmi dobrý.

Má už:

```systemverilog
hblank_o
vblank_o
blank_remaining_o
last_active_x_req_o
last_active_pixel_req_o
h_cnt_o
v_cnt_o
```

Toto je presne to, čo bude treba pre HDMI scheduler.

Dôležité: tieto signály ešte **nie sú privedené do `hdmi_tx_core`**. V `hdmi_tx_core.sv` sa stále robí:

```systemverilog
wire vblank = vsync_r;
wire hblank = ~de_r && ~vblank;
```

To je pre plné HDMI nedostatočné. `vsync` nie je celé `vblank`. Je to iba synchronizačný pulz.

Správny ďalší krok:

```systemverilog
input logic hblank_i,
input logic vblank_i,
input logic [15:0] blank_remaining_i,
input logic frame_start_i,
input logic line_start_i
```

pridať do `hdmi_tx_core`.

Hodnotenie:

```text
Timing generator: dobrý
Integrácia timing informácií do HDMI core: ešte nedokončená
```

---

# 2. Najväčší posun: pribudol `data_island_formatter.sv`

Toto je veľmi dôležitý krok.

Predtým bola data-island cesta iba:

```text
packet byte → pkt_byte[3:0] / pkt_byte[7:4] → TERC4
```

To nebolo HDMI-kompatibilné.

Teraz už máte samostatný blok:

```text
data_island_formatter
    vstup: HB0..HB2 + PB0..PB27
    výstup: ch0/ch1/ch2 4-bit nibbles
    plus BCH/ECC
```

To je správna vrstva.

`data_island_formatter.sv` už robí:

```text
+ header BCH ECC
+ subpacket BCH ECC
+ 32 symbol periods
+ 3× 4-bit nibble výstup pre TERC4
+ ch0 obsahuje header bit + sync + parity
+ ch1/ch2 nesú subpacket bity
```

Toto je zásadný posun smerom k plnému HDMI.

Ale problém je, že v `hdmi_tx_core.sv` ešte stále vidím starú zjednodušenú cestu:

```systemverilog
terc4_encoder u_terc4_ch0 (
  .nibble_i(pkt_byte[3:0]), .tmds_o(data_ch0)
);

terc4_encoder u_terc4_ch1 (
  .nibble_i(pkt_byte[7:4]), .tmds_o(data_ch1)
);

terc4_encoder u_terc4_ch2 (
  .nibble_i(4'h0), .tmds_o(data_ch2)
);
```

Čiže:

```text
data_island_formatter existuje,
ale ešte nie je zapojený do HDMI core.
```

Toto je najdôležitejší najbližší krok.

---

# 3. `hdmi_bch_ecc.sv`

Toto je ďalší veľký posun. Máte generický BCH/ECC modul:

```systemverilog
module hdmi_bch_ecc #(
  parameter int DATA_BITS = 24
)
```

Použitie:

```text
DATA_BITS=24 → header ECC
DATA_BITS=56 → subpacket ECC
```

To je správna architektonická vrstva.

Čo treba ešte spraviť:

```text
- overiť BCH výsledky proti známym HDMI packet test vectorom
- potvrdiť bit order
- potvrdiť init hodnotu a polynomial podľa oficiálnej HDMI špecifikácie
```

Samotný modul vyzerá dobre ako kombinačný ECC generátor, ale BCH je presne ten typ logiky, kde drobný bit-order rozdiel spôsobí nekompatibilný HDMI packet.

Hodnotenie:

```text
BCH/ECC infraštruktúra: pridaná
Overenie proti referencii: ešte potrebné
```

---

# 4. `packet_scheduler.sv` je teraz medzi dvoma svetmi

Aktuálny `packet_scheduler` stále vyrába **lineárny byte stream**:

```text
GCP_HEADER
GCP_BYTE0
AVI_HEADER
AVI_PAYLOAD
SPD_HEADER
SPD_PAYLOAD
AUDIO_HEADER
AUDIO_PAYLOAD
```

Ale nový `data_island_formatter` očakáva skôr kompletný packet:

```text
HB0, HB1, HB2
PB0..PB27
```

To znamená, že aktuálny `packet_scheduler` už architektonicky nesedí k novému formatteru.

Pre plné HDMI by som zmenil prístup:

## Namiesto byte stream scheduleru

```text
packet_scheduler
    ↓ byte po byte
TERC4
```

## Použiť packet arbiter

```text
avi_packet_builder
gcp_packet_builder
audio_info_packet_builder
acr_packet_builder
audio_sample_packetizer
        ↓
packet_arbiter
        ↓
hdmi_packet_t
        ↓
data_island_formatter
```

Čiže `packet_scheduler` by sa mal premeniť na:

```text
packet_arbiter
```

ktorý vyberie **celý packet**, nie jeden bajt.

Navrhovaný typ:

```systemverilog
typedef struct packed {
  logic [7:0] hb0;
  logic [7:0] hb1;
  logic [7:0] hb2;
  logic [7:0] pb [0:27];
  logic       valid;
} hdmi_packet_t;
```

Pozor: unpacked array v struct packed nie je v SystemVerilogu priamo vhodný, takže prakticky by som použil buď:

```systemverilog
logic [7:0] hb [0:2];
logic [7:0] pb [0:27];
```

ako samostatné porty, alebo packed vector:

```systemverilog
logic [23:0] hb_flat;
logic [223:0] pb_flat;
```

Aktuálny `packet_scheduler` je použiteľný ako dočasný generátor test dát, ale nie ako finálna packet vrstva pre `data_island_formatter`.

---

# 5. `hdmi_period_scheduler.sv` ešte nie je posunutý na novú úroveň

`hdmi_period_scheduler` stále nemá:

```systemverilog
blank_remaining_i
packet_len_i
data_island_ready_i
```

Stále spúšťa data island takto:

```systemverilog
else if (hblank_i && packet_pending_i)
```

To je rizikové.

Pre plný HDMI musí byť podmienka približne:

```systemverilog
if (hblank_i &&
    packet_pending_i &&
    blank_remaining_i >= DATA_ISLAND_TOTAL_LEN)
```

Dnes má scheduler fixne:

```text
8 preamble
2 guard lead
32 payload
2 guard trail
= 44 pixel clockov
```

Takže minimálne:

```systemverilog
input logic [15:0] blank_remaining_i;

if (hblank_i && packet_pending_i && blank_remaining_i >= 16'd44)
```

Bez toho sa data island môže začať príliš neskoro v blankingu a zasiahnuť do active video.

Dobrá správa: `video_timing_generator` už `blank_remaining_o` má. Len ho treba dotiahnuť až do `hdmi_tx_core` a scheduleru.

---

# 6. `hdmi_tx_core.sv` — hlavný integračný gap

Aktuálny `hdmi_tx_core` má dobrý DVI základ, ale HDMI data island integrácia je stále stará.

Aktuálne:

```text
packet_scheduler byte stream
    ↓
TERC4 priamo z pkt_byte
    ↓
channel_mux
```

Nové bloky by mali byť zapojené takto:

```text
infoframe_builder
    ↓
packet_arbiter / packet source
    ↓
data_island_formatter
    ↓
TERC4 encoder ×3
    ↓
channel_mux
```

Čiže v `hdmi_tx_core` by mala zmiznúť táto časť:

```systemverilog
.nibble_i(pkt_byte[3:0])
.nibble_i(pkt_byte[7:4])
.nibble_i(4'h0)
```

a nahradiť ju:

```systemverilog
logic [3:0] di_ch0, di_ch1, di_ch2;

data_island_formatter u_di_fmt (
  .clk_i     (pix_clk_i),
  .rst_ni    (rst_ni),
  .start_i   (packet_start),
  .advance_i (packet_pop),
  .hsync_i   (hsync_aligned),
  .vsync_i   (vsync_aligned),
  .hb        (selected_hb),
  .pb        (selected_pb),
  .ch0_o     (di_ch0),
  .ch1_o     (di_ch1),
  .ch2_o     (di_ch2)
);

terc4_encoder u_terc4_ch0 (
  .nibble_i(di_ch0),
  .tmds_o(data_ch0)
);
```

A hlavne `selected_hb/pb` musia byť celý vybraný packet, nie bajtový stream.

---

# 7. `hdmi_channel_mux.sv`

Mux je stále dobrý ako architektonická hranica.

Ale pre plné HDMI treba ešte doladiť:

```text
- preamble control hodnoty
- guard band hodnoty podľa kanála
- presný video guard band
- presné CTL0..CTL3 pre data/video preamble
```

Dnes `DATA_PREAMBLE` v podstate iba prepúšťa control symboly:

```systemverilog
HDMI_PERIOD_DATA_PREAMBLE: begin
  ch2_next = ctrl_ch2_i;
  ch1_next = ctrl_ch1_i;
  ch0_next = ctrl_ch0_i;
end
```

To je štrukturálne OK, ale len vtedy, ak `ctrl_ch1_i` a `ctrl_ch2_i` už obsahujú správne CTL hodnoty pre data island preambulu.

V `hdmi_tx_core` však zatiaľ `ctrl_ch1` a `ctrl_ch2` majú stále pevné:

```systemverilog
.ctrl_i(2'b00)
```

Pre data island preambulu to nebude stačiť.

Bude treba doplniť generátor CTL hodnôt:

```systemverilog
logic [1:0] ctl_ch0;
logic [1:0] ctl_ch1;
logic [1:0] ctl_ch2;
```

a nastavovať ich podľa `period` / „next period“.

---

# 8. `tmds_phy_ddr_aligned.sv`

Tu ste spravili veľký krok dopredu.

Pôvodný problém bol:

```text
CDC load_toggle → nezaručené 10-bit zarovnanie
```

Nový PHY má:

```text
pair_cnt 0..4
load word pri pair_cnt==4
shift po 2 bitoch
ALTDDIO_OUT výstup
```

To je správny prístup.

Zostáva fyzické riziko:

```text
pix_clk_i a clk_x_i musia byť PLL-generated a deterministicky fázované
reset musí byť bezpečný
constraints musia povedať nástroju, čo je vzťah medzi hodinami
```

`pix_clk_i` je v module stále iba port, ale nepoužíva sa. To je použiteľné ako dokumentačný port, ale syntéza môže hlásiť warning. Ak chceš čistejšie riešenie, buď:

```text
- použiť pix_clk_i na synchronizáciu load fázy
```

alebo:

```text
- odstrániť ho z portov PHY
```

Za mňa by som ho ponechal, ale využil ho neskôr na deterministické zarovnanie `pair_cnt`.

---

# 9. Video pipeline je teraz dobrá

Táto časť je podľa mňa už najzrelšia.

Máte:

```text
picture_gen_stream
video_stream_fifo_sync
video_stream_frame_aligner
video_timing_generator
vga_output_adapter
```

`video_timing_generator` už dáva aj HDMI scheduler signály.
`video_stream_frame_aligner` už rieši SOF a underflow lepšie než pôvodne.

Ešte by som doplnil do alignera reálnu kontrolu:

```systemverilog
if (pixel_take) begin
  if (s_axis_eol_i != last_active_x_i)
    sync_error_o = 1'b1;

  if (s_axis_eof_i != last_active_pixel_i)
    sync_error_o = 1'b1;
end
```

Teraz porty `last_active_x_i`, `last_active_pixel_i`, `s_axis_eol_i`, `s_axis_eof_i` existujú, ale v logike ich ešte nevidím použité.

Čiže:

```text
video timing + frame sync architektúra: dobrá
EOL/EOF integrita: ešte nedokončená
```

---

# 10. Ako sme postúpili vo vývoji HDMI

## Predchádzajúci stav

Projekt bol zhruba:

```text
DVI-like video
starý serializer
náznak packetov
bez reálneho data-island formatteru
bez BCH/ECC
```

## Aktuálny stav

Teraz je stav:

```text
DVI video core:
  veľmi dobrý základ

PHY:
  word-aligned DDR PHY pridaný

HDMI data island:
  BCH/ECC modul pridaný
  data_island_formatter pridaný
  ale ešte nie je zapojený do hdmi_tx_core

Packet layer:
  stále starý byte-stream scheduler
  treba prerobiť na packet arbiter

HDMI scheduler:
  FSM existuje
  ale ešte nepoužíva blank_remaining

Audio:
  zatiaľ ešte prakticky nezačaté
```

Teda progres je veľký hlavne v týchto oblastiach:

```text
1. fyzická TMDS vrstva
2. data-island formatter kostra
3. BCH/ECC kostra
4. lepší video timing
5. lepšie modulárne rozdelenie
```

Ale ešte chýba integrácia:

```text
packet source → data_island_formatter → TERC4 → channel mux
```

---

# 11. Aktuálna technická úroveň

Moje hodnotenie:

```text
DVI-compatible HDMI video:
  80–90 % architektonicky hotové

Word-aligned PHY:
  70–80 %, potrebuje constraints/reset/fázové overenie

AVI InfoFrame builder:
  70 %, builder OK, ale nie je pripojený cez správny packet path

BCH/ECC:
  50–60 %, modul existuje, treba overiť test vectormi

Data island formatter:
  50 %, modul existuje, treba overiť a integrovať

HDMI period scheduler:
  50 %, FSM existuje, chýba blank_remaining a packet-level handshake

Packet scheduler/arbiter:
  30 %, starý byte-stream model treba nahradiť packet arbitrom

Audio:
  0–10 %, zatiaľ chýba ACR, audio sample packetizer, audio FIFO
```

---

# 12. Najbližší správny krok

Najbližší krok by som zvolil veľmi konkrétne:

```text
Integrovať data_island_formatter do hdmi_tx_core
a poslať jeden AVI InfoFrame packet.
```

Nie audio. Nie viac packetov. Iba jeden packet.

Cieľová cesta:

```text
infoframe_builder AVI
    ↓
packet select / hb,pb arrays
    ↓
data_island_formatter
    ↓
TERC4 encoder ×3
    ↓
hdmi_channel_mux
```

Zároveň uprav `hdmi_period_scheduler`, aby prijal:

```systemverilog
blank_remaining_i
```

a spúšťal data island iba keď:

```systemverilog
blank_remaining_i >= 16'd44
```

Tým sa dostanete k prvému reálnemu HDMI data-island packetu.

---

# 13. Čo by som teraz nerobil

Zatiaľ by som nerobil:

```text
- audio sample packetizer
- ACR N/CTS
- SPD packet
- Audio InfoFrame
- EDID
- deep color
```

Kým nebude fungovať jeden AVI InfoFrame cez skutočný `data_island_formatter`, všetko ostatné bude ťažko debugovateľné.

---

# Záver

Postúpili ste výrazne.

Už máte:

```text
+ dobrý DVI/TMDS video základ
+ oddelený HDMI core
+ samostatný PHY
+ BCH/ECC modul
+ data_island_formatter
+ lepší timing generator s blank_remaining
```

Ale projekt je teraz v prechodovej fáze:

```text
nové plnohodnotné data-island bloky existujú,
ale hdmi_tx_core stále používa starý byte-stream → TERC4 shortcut.
```

Najbližší veľký míľnik je teda jasný:

```text
odstrániť byte-stream TERC4 shortcut
a zapojiť:
InfoFrame builder → data_island_formatter → TERC4 → channel mux
```

Keď toto prejde simuláciou a monitor/HDMI analyzer uvidí AVI InfoFrame, budete mať prvý skutočný štandardnejší HDMI krok za sebou.
