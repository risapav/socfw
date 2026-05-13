Teraz je refaktor už citeľne posunutý správnym smerom. V aktuálnej verzii sú opravené viaceré veci, ktoré boli predtým problémové:

```text id="dts0jn"
+ vga_hdmi_tx už pripája hblank/vblank/frame_start/blank_remaining do hdmi_tx_core
+ vga_hdmi_tx už používa tmds_phy_ddr_aligned, nie generic_serializer
+ hdmi_period_scheduler už používa blank_remaining_i
+ data_island_formatter je už zapojený do hdmi_tx_core
+ TERC4 už ide z data_island_formatter, nie priamo z bajtu
+ video_timing_generator už generuje blank_remaining a request-phase last pixel signály
+ video_stream_frame_aligner už kontroluje EOL/EOF oproti timing pozícii
```

To znamená, že projekt už nie je len DVI-like core s náznakom HDMI. Teraz už máš prvú reálnu architektúru pre HDMI data island.

---

# 1. Aktuálny stav architektúry

Momentálna hlavná cesta vyzerá takto:

```text id="d3pz40"
vga_hdmi_tx
    ↓
RGB565 → RGB888
    ↓
hdmi_tx_core
    ├── tmds_video_encoder ×3
    ├── tmds_control_encoder ×3
    ├── infoframe_builder AVI
    ├── data_island_formatter
    ├── TERC4 encoder ×3
    ├── hdmi_period_scheduler
    └── hdmi_channel_mux
    ↓
tmds_phy_ddr_aligned
    ↓
HDMI TMDS pins
```

Toto je už veľmi blízko odporúčanej vrstvenej architektúre:

```text id="o0lvy5"
video timing / stream
    ↓
HDMI core
    ↓
data island formatter
    ↓
TERC4
    ↓
TMDS mux
    ↓
PHY
```

---

# 2. `vga_hdmi_tx.sv` — výrazne lepší stav

Tento wrapper je teraz v súlade s návrhom.

Pozitíva:

```text id="a946sj"
+ prijíma explicitné hblank_i/vblank_i/frame_start_i/blank_remaining_i
+ nepokúša sa odvodiť vblank z VSYNC
+ používa hdmi_tx_core
+ používa tmds_phy_ddr_aligned
+ RGB565 → RGB888 je jednoduché a správne
```

Dôležité je, že už máš:

```systemverilog id="x1j06o"
.hblank_i         (hblank_i),
.vblank_i         (vblank_i),
.frame_start_i    (frame_start_i),
.blank_remaining_i(blank_remaining_i),
```

a následne:

```systemverilog id="h5w1lc"
tmds_phy_ddr_aligned u_phy (...)
```

To je presne smer, ktorý sme chceli.

### Zostáva

`frame_start_i` sa v `hdmi_tx_core` zatiaľ nepoužíva. Nie je to chyba, ale neskôr bude vhodný na:

```text id="htw3tt"
- plánovanie AVI InfoFrame raz za frame
- plánovanie Audio InfoFrame
- reset/periodické požiadavky packet arbitra
```

Teraz sa v `hdmi_tx_core` pending nastavuje cez nábežnú hranu `vsync_r`. To je menej všeobecné než `frame_start_i`.

---

# 3. `hdmi_tx_core.sv` — veľký pokrok

Toto je najdôležitejší posun. V core už nie je stará skratka:

```text id="f8u81h"
pkt_byte[3:0] → TERC4
pkt_byte[7:4] → TERC4
```

Namiesto toho už máš:

```systemverilog id="k06v16"
data_island_formatter u_formatter (
  .start_i  (packet_start),
  .advance_i(packet_pop),
  .hsync_i  (hsync_r),
  .vsync_i  (vsync_r),
  .hb       (hdr_avi),
  .pb       (pb_avi),
  .ch0_o    (di_ch0),
  .ch1_o    (di_ch1),
  .ch2_o    (di_ch2)
);
```

a potom:

```systemverilog id="zkw35c"
terc4_encoder u_terc4_ch0 (.nibble_i(di_ch0), ...)
terc4_encoder u_terc4_ch1 (.nibble_i(di_ch1), ...)
terc4_encoder u_terc4_ch2 (.nibble_i(di_ch2), ...)
```

Toto je správna štruktúra.

Aktuálne teda podporuješ prvý konkrétny HDMI data island cieľ:

```text id="fxtbpm"
AVI InfoFrame → data_island_formatter → TERC4 → TMDS mux
```

To je veľký krok smerom k plnému HDMI.

---

# 4. Kritický problém: latencia data island vetvy

Tu je teraz najväčšia technická vec na overenie.

V `hdmi_period_scheduler` je `packet_pop_o` aktívny počas `ST_DATA_PAYLOAD`. `data_island_formatter` pri `advance_i` posunie shift registre v `always_ff`, ale jeho výstupy `ch0_o/ch1_o/ch2_o` sú kombinačné zo stavov `hdr_sr/sp_sr`.

TERC4 enkóder má registrovaný výstup:

```systemverilog id="gyg6tr"
always_ff @(posedge clk_i) begin
  tmds_o <= lut;
end
```

Čiže data path má minimálne:

```text id="f6ek7q"
formatter shift register → TERC4 register → channel mux register
```

Scheduler period ide cez:

```systemverilog id="ca3u9h"
period_d1 <= period;
```

a potom do muxu.

Riziko: `period_d1 == HDMI_PERIOD_DATA_PAYLOAD` nemusí byť presne zarovnané s platným `data_ch*` z TERC4. Ak je TERC4 o 1 takt za `di_ch*`, a mux má ďalší register, musí byť aj `period` oneskorený o zodpovedajúci počet taktov.

Momentálne komentár hovorí „TERC4 latency matches video encoder latency“, ale reálne TERC4 má len 1 register, zatiaľ čo video encoder má 2 takty. Navyše formatter má vlastné registre.

### Odporúčanie

Zaveď explicitné lokálne parametre:

```systemverilog id="ev2brd"
localparam int VIDEO_LATENCY  = 2;
localparam int CTRL_LATENCY   = 2;
localparam int TERC4_LATENCY  = 1;
localparam int MUX_LATENCY    = 1;
```

A potom vedome zarovnaj:

```text id="6ky6s2"
period_for_mux
data_for_mux
video_for_mux
control_for_mux
```

Pre prvý test by som v simulácii sledoval:

```text id="g413re"
packet_start
packet_pop
formatter sym_cnt
di_ch0/1/2
data_ch0/1/2
period
period_d1
ch0_o/ch1_o/ch2_o
```

Cieľ: prvý payload symbol z formattera musí byť vybraný muxom práve počas prvého `HDMI_PERIOD_DATA_PAYLOAD` výstupného cyklu.

---

# 5. `hdmi_period_scheduler.sv` — veľký posun

Scheduler už má:

```systemverilog id="j3wvhy"
input logic [15:0] blank_remaining_i
```

a správnu podmienku:

```systemverilog id="y6tngk"
hblank_i && packet_pending_i &&
blank_remaining_i >= 16'(ISLAND_TOTAL + VIDEO_PRE_TOTAL)
```

To je veľmi dobré. Už nechceš spustiť data island, ak sa nezmestí do blankingu.

Tiež už má video preamble a video guard band:

```text id="4lp4l8"
ST_VIDEO_PREAMBLE
ST_VIDEO_GB
ST_VIDEO
```

To je ďalší posun k plnému HDMI.

### Pozor na presnú hranicu `blank_remaining_i == VIDEO_PRE_TOTAL`

Táto časť:

```systemverilog id="d0p5tk"
else if (hblank_i &&
         blank_remaining_i == 16'(VIDEO_PRE_TOTAL)) begin
  state_next = ST_VIDEO_PREAMBLE;
end
```

je elegantná, ale krehká. Ak sa `blank_remaining_i` kvôli registrácii posunie o 1 takt, video preamble sa nikdy nespustí.

Odporúčam zvážiť robustnejšiu podmienku:

```systemverilog id="56769m"
blank_remaining_i <= VIDEO_PRE_TOTAL
```

s ochranou, aby sa preamble nespustila opakovane.

Napríklad:

```systemverilog id="i1mi0p"
else if (hblank_i &&
         blank_remaining_i <= VIDEO_PRE_TOTAL &&
         blank_remaining_i != 0) begin
```

Ale toto treba spraviť opatrne, aby sa preamble nezačala príliš skoro alebo viackrát.

### Ďalší problém: `packet_start_o` je na začiatku preambuly

Scheduler dáva:

```systemverilog id="1yn5zy"
packet_start_o = 1'b1;
```

pri vstupe do `ST_DATA_PREAMBLE`.

To znamená, že formatter načíta packet 8 + 2 cyklov pred payloadom. To je v poriadku. Len treba overiť, že `packet_pop_o` začne až počas payloadu, čo u teba platí.

---

# 6. `data_island_formatter.sv` — dobrý základ, ale treba overiť bit order a ch0 mapping

Tento modul je veľmi dôležitý. Aktuálne robí:

```text id="wo3k6a"
HB0..HB2 + header BCH
PB0..PB27 + subpacket BCH
→ 32 symbolov
→ ch0/ch1/ch2 TERC4 nibbles
```

To je správna koncepcia.

### Veľmi dobré

```systemverilog id="8ijbzq"
wire [31:0] hdr_bits = {bch_hdr, hb[2], hb[1], hb[0]};
```

a:

```systemverilog id="7khg9g"
assign sp_bits[k] = {bch_sp[k],
                     pb[7*k+6], ..., pb[7*k+0]};
```

Následne shiftuješ doprava, takže sa posiela LSB-first. To je konzistentné s komentárom.

### Vec na overenie

Toto je presne typ bloku, kde malá chyba v poradí bitov spôsobí, že monitor InfoFrame neuvidí:

```text id="1zwfis"
- poradie HB0/HB1/HB2
- poradie BCH byte
- poradie PB v subpacketoch
- či BCH ide pred alebo po dátach v serializovanom toku
- ch0 bitové pole {parity, hdr_bit, vsync, hsync}
```

Bez test vectoru by som ho ešte nepovažoval za overený.

### Možný problém s `ch0_o`

Máš:

```systemverilog id="tl23xb"
assign ch0_o = {parity, hdr_bit, vsync_i, hsync_i};
```

V komentári píšeš:

```text id="s4b3f7"
ch0 = { parity, header_bit[p], vsync, hsync }
```

To môže byť správne podľa tvojej zvolenej bitovej konvencie pre TERC4 nibble, ale musíš to overiť voči HDMI špecifikácii. Hlavne preto, že inde používaš control symbol:

```systemverilog id="v5e5ro"
.ctrl_i({vsync_r, hsync_r})
```

Čiže konzistencia HS/VS bitov je dôležitá.

---

# 7. `hdmi_bch_ecc.sv` — dobrý modul, ale stále vyžaduje testbench

BCH generátor je už pekne izolovaný. To je správne.

Ale opäť: pri BCH sú riziká:

```text id="b69ef2"
- initial value 8'hFF
- polynomial 0x1D
- LSB-first
- či ecc_o má byť lfsr alebo invertovaný/bitovo otočený
```

Komentár tvrdí jasnú konvenciu:

```text id="hnwvsl"
Bits processed LSB-first per byte
Initial LFSR 8'hFF
Polynomial 0x1D
```

To je dobré, ale ďalší krok musí byť testbench s referenčnými hodnotami.

---

# 8. `hdmi_channel_mux.sv` — stále najviac „placeholder“ časť HDMI režimu

Mux už pozná:

```text id="xkk5ap"
VIDEO
VIDEO_GB
DATA_PREAMBLE
DATA_GB
DATA_PAYLOAD
```

To je dobré.

Ale stále má pevné guard band symboly:

```systemverilog id="puwxt7"
GB_DATA_0 = 10'b0100110011;
GB_DATA_N = 10'b0100110011;
```

A `DATA_PREAMBLE` iba prepúšťa control symboly:

```systemverilog id="o8gqgt"
ch2_next = ctrl_ch2_i;
ch1_next = ctrl_ch1_i;
ch0_next = ctrl_ch0_i;
```

Problém: v `hdmi_tx_core` stále generuješ:

```systemverilog id="bketqo"
ctrl_ch2 = control(2'b00)
ctrl_ch1 = control(2'b00)
```

Počas data island preambuly však kanály 1/2 majú signalizovať, aký typ periódy nasleduje. Ak zostanú `2'b00`, preambula nemusí byť správna.

### Čo treba doplniť

V `hdmi_tx_core` treba vybrať control hodnoty podľa obdobia:

```systemverilog id="wj6b22"
logic [1:0] ctl_ch0;
logic [1:0] ctl_ch1;
logic [1:0] ctl_ch2;

assign ctl_ch0 = {vsync_r, hsync_r};

always_comb begin
  ctl_ch1 = 2'b00;
  ctl_ch2 = 2'b00;

  if (period == HDMI_PERIOD_DATA_PREAMBLE) begin
    ctl_ch1 = ...; // podľa HDMI data island preamble
    ctl_ch2 = ...;
  end else if (period == HDMI_PERIOD_VIDEO_PREAMBLE) begin
    ctl_ch1 = ...; // podľa video preamble
    ctl_ch2 = ...;
  end
end
```

Toto je potrebné pre plný HDMI režim.

---

# 9. `tmds_phy_ddr_aligned.sv` — správna náhrada za generic serializer

V tejto verzii už `vga_hdmi_tx` používa `tmds_phy_ddr_aligned`. To je správne.

Modul robí:

```text id="qts6yn"
pair_cnt 0..4
load TMDS word pri pair_cnt==4
shift o 2 bity
ALTDDIO_OUT
```

To je podstatne lepšie než pôvodný `generic_serializer`.

### Riziko

Stále je to crossing z pixel-clock domény do `clk_x_i` domény bez explicitného handshake, ale spolieha sa na PLL fázový vzťah. To je pri TMDS serializeri bežný prístup, ale musí byť podchytený constraints.

Komentár to už dobre dokumentuje:

```text id="g7q0rv"
clk_x_i = 5 × pixel_clock
PLL co-generated
multicycle path
```

Toto treba premietnuť do `.sdc`/constraints. Bez toho môže nástroj hlásiť falošné alebo reálne timing problémy.

---

# 10. `tmds_video_encoder.sv` — architektonicky OK, ale overiť referenčne

Encoder má:

```text id="p9cs7e"
+ de_i
+ 2-stage pipeline
+ running disparity reset počas blankingu
+ jasnú q_m[8] konvenciu
```

To je správne.

Naďalej odporúčam testbench proti referenčnému TMDS encoderu. Nie preto, že by kód očividne vyzeral zle, ale preto, že TMDS balance algoritmus je citlivý na jednu podmienku alebo bit polarity.

---

# 11. Video pipeline — dobrý stav

`video_timing_generator` a `video_stream_frame_aligner` sú už v dobrom stave.

Dobré veci:

```text id="d8qi3n"
+ pixel_req_o je look-ahead
+ frame_start_o je request-phase
+ last_active_x_req_o a last_active_pixel_req_o existujú
+ frame_aligner nezahadzuje SOF
+ frame_aligner už kontroluje EOL/EOF
+ underflow ide do DROP_BROKEN_FRAME
```

Toto je už veľmi použiteľná video stream infraštruktúra.

Jedna drobnosť: v `video_stream_frame_aligner` máš:

```systemverilog id="o62eh8"
wire pixel_take = pixel_req_i && (state_next == ST_STREAM_FRAME) && s_axis_valid_i;
```

Použitie `state_next` je zámerné kvôli prvému pixelu pri frame_start, ale je to trochu neštandardné. Funguje, ak si si istý, že `s_axis_ready_o` je v tom istom cykle konzistentné. Pre čitateľnosť by som možno pridal explicitný signál:

```systemverilog id="60m9ka"
wire entering_stream = (state == ST_WAIT_FRAME_START) && frame_start_i;
wire streaming_now   = (state == ST_STREAM_FRAME) || entering_stream;
wire pixel_take      = pixel_req_i && streaming_now && s_axis_valid_i;
```

Funkčne to bude jasnejšie.

---

# 12. `packet_scheduler.sv` je už prakticky legacy

Tento súbor je stále v projekte, ale `hdmi_tx_core` ho už nepoužíva. Teraz ide AVI priamo cez `infoframe_builder → data_island_formatter`.

To je správny smer.

Odporúčanie:

```text id="4r7z4v"
packet_scheduler.sv presuň do legacy/
alebo ho neskôr nahraď packet_arbiter.sv
```

Pre plné HDMI budeš potrebovať nový blok:

```text id="j8s2q5"
hdmi_packet_arbiter
```

nie byte-stream scheduler.

---

# 13. Najväčšie aktuálne riziká

Podľa aktuálneho kódu sú top riziká:

```text id="y5a92a"
1. Latencia medzi schedulerom, formatterom, TERC4 a muxom.
2. Správnosť BCH/ECC bit orderu.
3. Správnosť data island bit mappingu.
4. Preamble/CTL hodnoty pre video/data island.
5. Guard band symboly, hlavne data CH0.
6. TMDS PHY constraints a fázové zarovnanie.
```

Toto sú už „HDMI presnosť“ problémy, nie základné architektonické chyby. To je dobrý znak.

---

# 14. Ako ste postúpili

Predtým:

```text id="x40fsr"
DVI video core
+ starý serializer
+ byte-to-TERC4 skratka
+ neúplný scheduler
```

Teraz:

```text id="dvvaw9"
DVI/TMDS video core
+ word-aligned PHY
+ explicit blanking timing
+ scheduler s blank_remaining
+ video preamble/video guard states
+ data_island_formatter
+ BCH/ECC modul
+ AVI InfoFrame cesta do formatteru
```

To je veľký posun. Aktuálny projekt je teraz na úrovni:

```text id="d58i2z"
prvý pokus o skutočný HDMI data island s AVI InfoFrame
```

Ešte to nie je plné HDMI s audio, ale už to má správne vrstvy.

---

# 15. Odporúčaný ďalší postup

## Krok 1: Simulačne overiť data island timing

Sprav testbench pre `hdmi_tx_core` s:

```text id="jso9ri"
ENABLE_DATA_ISLAND=1
krátky video mód
packet_pending raz za frame
hblank s dostatočným blank_remaining
```

Sleduj:

```text id="fn3fdy"
period
packet_start
packet_pop
formatter active_o
formatter sym_cnt
di_ch0/ch1/ch2
data_ch0/ch1/ch2
ch0_o/ch1_o/ch2_o
```

Cieľ:

```text id="r3l29d"
presne 8 preamble
2 guard
32 payload
2 guard
10 video preamble/guard pred DE
žiadny data payload počas DE
```

---

## Krok 2: Testbench pre BCH/ECC

Sprav samostatné testy:

```text id="ni6nwa"
hdmi_bch_ecc DATA_BITS=24
hdmi_bch_ecc DATA_BITS=56
data_island_formatter s fixným AVI packetom
```

Porovnať s referenčnými očakávanými hodnotami.

---

## Krok 3: Opraviť CTL/preamble generovanie

Doplniť do `hdmi_tx_core` generovanie `ctl_ch1/ctl_ch2` podľa preambuly.

Teraz sú stále pevné `2'b00`. To je potrebné opraviť pred tým, než bude data island štandardovo správny.

---

## Krok 4: Opraviť guard bandy

Hlavne:

```text id="lfdcwe"
data island CH0 guard band
```

nesmie zostať pevný placeholder, ak podľa špecifikácie závisí od HS/VS cez TERC4 nibble.

---

## Krok 5: Až potom pridať packet arbiter

Keď AVI InfoFrame funguje, pridaj:

```text id="6kpd95"
hdmi_packet_arbiter
```

Poradie zdrojov:

```text id="ecgfhz"
1. GCP
2. AVI InfoFrame
3. Audio InfoFrame
4. ACR
5. Audio Sample Packet
```

---

## Krok 6: Audio až po stabilnom AVI InfoFrame

Pre audio bude treba:

```text id="e2xw19"
audio_sample_fifo
ACR N/CTS generator
audio_infoframe_builder
audio_sample_packetizer
packet_arbiter
```

Prvý cieľ:

```text id="5jpjzl"
2ch LPCM
48 kHz
16 alebo 24 bit
```

---

# Záver

Aktuálny refaktor je veľký krok dopredu. Už máte:

```text id="nhzdyv"
+ správnu HDMI core / PHY separáciu
+ word-aligned TMDS PHY
+ data island scheduler s blank_remaining
+ data_island_formatter
+ BCH/ECC blok
+ AVI InfoFrame cestu do formatteru
```

Najväčšia zostávajúca práca už nie je „ako to rozdeliť“, ale **presne zladiť HDMI data-island protokol**:

```text id="wq5bxy"
latencie
preamble CTL hodnoty
guard bandy
BCH bit order
data island bit mapping
```

Ďalší najlepší krok: **neskákať ešte na audio**, ale najprv simulačne a prakticky overiť jeden AVI InfoFrame cez data island. Keď monitor alebo analyzer uvidí korektný AVI InfoFrame, až potom má zmysel pridávať GCP, ACR a audio.
