Áno. V tejto sade je viditeľný posun smerom k plnému HDMI, ale kód je teraz v **prechodnom nekonzistentnom stave**: niektoré nové bloky už existujú, ale nie sú správne zapojené, a niektoré rozhrania medzi súbormi si navzájom nesedia.

Najkratšie hodnotenie:

```text
Video/DVI základ:      dobrý smer
TMDS PHY:              nový správny blok existuje, ale wrapper ho nepoužíva
Data island formatter: existuje, ale hdmi_tx_core ho nepoužíva
Scheduler:             ešte nepoužíva blank_remaining
Audio:                 zatiaľ nezačaté
Kompilácia:            aktuálna sada pravdepodobne neprejde bez úprav
```

---

## 1. Najväčší problém: súbory nie sú navzájom zosúladené

### `hdmi_tx_core.sv` očakáva nové timing vstupy

V `hdmi_tx_core.sv` už máš správne rozšírené rozhranie:

```systemverilog
input  logic        hblank_i,
input  logic        vblank_i,
input  logic        frame_start_i,
input  logic [15:0] blank_remaining_i,
```

To je dobrý krok. Presne toto treba pre plný HDMI scheduler.

Lenže `vga_hdmi_tx.sv` ich do `hdmi_tx_core` nepripája. V aktuálnom `vga_hdmi_tx.sv` inštancia `hdmi_tx_core` končí približne takto:

```systemverilog
.de_i          (vga_de_i),
.hsync_i       (vga_hs_i),
.vsync_i       (vga_vs_i),
.info_cfg_i    ('0),
...
```

Chýbajú:

```systemverilog
.hblank_i(...)
.vblank_i(...)
.frame_start_i(...)
.blank_remaining_i(...)
```

To znamená, že aktuálna kombinácia `vga_hdmi_tx.sv` + `hdmi_tx_core.sv` pravdepodobne neprejde elaboráciou/kompiláciou.

### Čo opraviť

Buď do `vga_hdmi_tx` pridaj porty:

```systemverilog
input logic        hblank_i,
input logic        vblank_i,
input logic        frame_start_i,
input logic [15:0] blank_remaining_i,
```

a prepoj ich do `hdmi_tx_core`, alebo nech `vga_hdmi_tx` zatiaľ ostane DVI-only wrapper a tieto signály nepoužíva. Pre plný HDMI ich však budeš potrebovať.

---

## 2. `hdmi_tx_core` volá scheduler s portom, ktorý scheduler nemá

V `hdmi_tx_core.sv` máš:

```systemverilog
.blank_remaining_i (blank_remaining_r),
```

pri inštancii `hdmi_period_scheduler`.

Lenže aktuálny `hdmi_period_scheduler.sv` má vstupy:

```systemverilog
input logic de_i,
input logic hblank_i,
input logic vblank_i,
input logic packet_pending_i,
```

ale **nemá**:

```systemverilog
input logic [15:0] blank_remaining_i
```

Toto je ďalšia kompilovateľnostná chyba.

### Čo opraviť v `hdmi_period_scheduler`

Doplň port:

```systemverilog
input logic [15:0] blank_remaining_i,
```

a v `ST_CONTROL` zmeň štart data islandu z:

```systemverilog
else if (hblank_i && packet_pending_i) begin
```

na:

```systemverilog
localparam int DATA_ISLAND_TOTAL_LEN = 8 + 2 + 32 + 2;

else if (hblank_i &&
         packet_pending_i &&
         blank_remaining_i >= DATA_ISLAND_TOTAL_LEN) begin
```

Bez toho sa data island môže začať príliš neskoro v blankingu a prejsť do aktívneho videa.

---

## 3. Pribudol `data_island_formatter`, ale `hdmi_tx_core` ho ešte nepoužíva

Toto je najdôležitejší architektonický bod.

Máte nový modul:

```systemverilog
data_island_formatter.sv
```

Ten už robí presne tú vrstvu, ktorá predtým chýbala:

```text
HB0..HB2 + PB0..PB27
    ↓
BCH/ECC
    ↓
32 data-island symbol periods
    ↓
ch0/ch1/ch2 4-bit TERC4 nibbles
```

To je výborný posun.

Lenže v `hdmi_tx_core.sv` je stále stará zjednodušená cesta:

```systemverilog
terc4_encoder u_terc4_ch0 (
  .nibble_i(pkt_byte[3:0]),
  .tmds_o(data_ch0)
);

terc4_encoder u_terc4_ch1 (
  .nibble_i(pkt_byte[7:4]),
  .tmds_o(data_ch1)
);

terc4_encoder u_terc4_ch2 (
  .nibble_i(4'h0),
  .tmds_o(data_ch2)
);
```

Toto ešte nie je HDMI data island. Je to byte-to-TERC4 skratka.

### Čo má byť namiesto toho

V `hdmi_tx_core` má byť približne:

```systemverilog
logic [7:0] hb [0:2];
logic [7:0] pb [0:27];

logic [3:0] di_ch0;
logic [3:0] di_ch1;
logic [3:0] di_ch2;

data_island_formatter u_di_fmt (
  .clk_i     (pix_clk_i),
  .rst_ni    (rst_ni),

  .start_i   (packet_start),
  .advance_i (packet_pop),

  .hsync_i   (hsync_r),
  .vsync_i   (vsync_r),

  .hb        (hb),
  .pb        (pb),

  .ch0_o     (di_ch0),
  .ch1_o     (di_ch1),
  .ch2_o     (di_ch2)
);

terc4_encoder u_terc4_ch0 (
  .clk_i    (pix_clk_i),
  .rst_ni   (rst_ni),
  .nibble_i (di_ch0),
  .tmds_o   (data_ch0)
);

terc4_encoder u_terc4_ch1 (
  .clk_i    (pix_clk_i),
  .rst_ni   (rst_ni),
  .nibble_i (di_ch1),
  .tmds_o   (data_ch1)
);

terc4_encoder u_terc4_ch2 (
  .clk_i    (pix_clk_i),
  .rst_ni   (rst_ni),
  .nibble_i (di_ch2),
  .tmds_o   (data_ch2)
);
```

Tým odstrániš najväčšiu neštandardnú časť.

---

## 4. `packet_scheduler` už architektonicky nesedí k novému formatteru

Aktuálny `packet_scheduler.sv` stále generuje **jeden bajt naraz**:

```systemverilog
output logic [7:0] packet_o,
output logic       packet_ready_o,
input  logic       consume_i
```

To sedelo k starej skratke:

```text
pkt_byte → TERC4
```

Ale nesedí k novému `data_island_formatter`, ktorý chce naraz kompletný packet:

```text
HB0..HB2 + PB0..PB27
```

Preto by som `packet_scheduler` už nepoužíval ako finálny blok pre HDMI data islands.

### Čo namiesto neho

Prerobiť ho na **packet arbiter**:

```text
GCP builder
AVI InfoFrame builder
Audio InfoFrame builder
ACR packet builder
Audio sample packetizer
        ↓
packet_arbiter
        ↓
hb[0:2], pb[0:27], packet_valid
        ↓
data_island_formatter
```

Čiže ďalší refaktor by mal byť:

```text
packet_scheduler byte-stream  →  hdmi_packet_arbiter packet-level
```

Minimálne pre prvý krok môžeš urobiť veľmi jednoduchý arbiter:

```text
ak frame_start:
    vyber AVI InfoFrame
inak:
    nič
```

Nemusíš hneď riešiť GCP, ACR ani audio.

---

## 5. `hdmi_bch_ecc.sv` je správny typ bloku, ale potrebuje test vectors

Pribudol `hdmi_bch_ecc.sv`, čo je veľký krok k plnému HDMI. Blok má generický parameter:

```systemverilog
parameter int DATA_BITS = 24
```

a tým vie pokryť:

```text
24-bit header ECC
56-bit subpacket ECC
```

To je správne delenie.

Riziko: BCH/ECC je citlivé na:

```text
bit order
byte order
initial LFSR value
polynomial
inverziu výsledku
```

Aj malý bit-order rozdiel spôsobí, že HDMI sink packet odmietne.

### Ďalší krok

Urob testbench:

```text
známy HB/PB packet
    ↓
očakávaný BCH ECC
```

a porovnaj výstup. Bez toho by som `data_island_formatter` nepovažoval za overený.

---

## 6. `hdmi_period_scheduler` ešte nerieši video preambulu/guard band

V `hdmi_pkg.sv` už máš:

```systemverilog
HDMI_PERIOD_VIDEO_PREAMBLE
HDMI_PERIOD_VIDEO_GB
```

a `hdmi_channel_mux.sv` ich už vie muxovať.

Ale `hdmi_period_scheduler.sv` ich negeneruje. Scheduler má iba:

```text
CONTROL
VIDEO
DATA_PREAMBLE
DATA_GUARD_LEAD
DATA_PAYLOAD
DATA_GUARD_TRAIL
```

Pre DVI-like video je to v poriadku. Pre plné HDMI po data islandoch bude treba riešiť aj správny prechod späť do video periódy:

```text
control/video preamble
video guard band
video data period
```

Toto nemusí byť prvá vec, ktorú opravíš, ale pre finálne HDMI to bude potrebné.

---

## 7. `hdmi_channel_mux.sv` je dobrý koncept, ale data guard band ch0 je zatiaľ placeholder

V `hdmi_channel_mux.sv` máš:

```systemverilog
localparam tmds_word_t GB_DATA_0 = 10'b0100110011;
```

a komentár:

```systemverilog
// ch0 data island GB should be TERC4({1,vsync,hsync,1}) — dynamic, deferred
```

Toto je dobrý komentár a zároveň jasne hovorí, čo ešte nie je hotové.

Pre plný HDMI musí byť data island guard band na CH0 dynamický podľa HSYNC/VSYNC. Nemal by byť pevný placeholder.

### Ďalší krok

Do muxu alebo do samostatného guard-band generátora pridaj:

```systemverilog
input logic hsync_i;
input logic vsync_i;
```

alebo mu priamo dodaj hotový:

```systemverilog
input tmds_word_t data_gb_ch0_i;
```

a vypočítaj ho cez TERC4 mapovanie správneho nibbla.

---

## 8. `vga_hdmi_tx.sv` používa stále `generic_serializer`, nie `tmds_phy_ddr_aligned`

Toto je regresia oproti cieľovej architektúre.

Máš nový správnejší modul:

```text
tmds_phy_ddr_aligned.sv
```

ale `vga_hdmi_tx.sv` stále používa:

```systemverilog
generic_serializer u_phy (...)
```

To je v rozpore s návrhom, pretože `generic_serializer` je všeobecný CDC/toggle serializer a nie je garantovane TMDS word-aligned.

### Čo opraviť

V `vga_hdmi_tx.sv` nahraď:

```systemverilog
generic_serializer u_phy (...)
```

za:

```systemverilog
tmds_phy_ddr_aligned u_phy (
  .pix_clk_i (clk_i),
  .clk_x_i   (clk_x_i),
  .rst_ni    (rst_ni),
  .ch0_i     (ch0),
  .ch1_i     (ch1),
  .ch2_i     (ch2),
  .clk_ch_i  (TMDS_CLK),
  .hdmi_p_o  (hdmi_p_o)
);
```

Toto je dôležité ešte pred ďalším ladením data islands.

---

## 9. `video_timing_generator` je dobrý a pripravený pre HDMI scheduler

Toto je jedna z najlepšie posunutých častí.

Má:

```systemverilog
hblank_o
vblank_o
blank_remaining_o
last_active_x_req_o
last_active_pixel_req_o
h_cnt_o
v_cnt_o
```

To je presne to, čo treba.

`blank_remaining_o` používa:

```systemverilog
if (!v_active)
  blank_remaining_comb = 16'hFFFF;
else if (!h_active)
  blank_remaining_comb = 16'(H_TOTAL) - 16'(h_cnt);
else
  blank_remaining_comb = 16'd0;
```

Toto je dobrý praktický začiatok. Pre vertical blanking dáva veľké číslo, čo scheduleru dovolí vložiť packet. Pre horizontal blanking dáva počet taktov do konca riadku.

Tento signál treba teraz len dostať až do `hdmi_period_scheduler`.

---

## 10. `video_stream_frame_aligner` má lepšiu architektúru, ale EOL/EOF kontrola ešte chýba

Porty na to už máš:

```systemverilog
last_active_x_i
last_active_pixel_i
s_axis_eol_i
s_axis_eof_i
```

ale v logike sa zatiaľ nepoužívajú na kontrolu integrity.

Pre robustný video stream by som pri `pixel_take` doplnil:

```systemverilog
if (pixel_take) begin
  if (s_axis_eol_i != last_active_x_i) begin
    sync_error_o = 1'b1;
    state_next   = ST_DROP_BROKEN_FRAME;
  end

  if (s_axis_eof_i != last_active_pixel_i) begin
    sync_error_o = 1'b1;
    state_next   = ST_DROP_BROKEN_FRAME;
  end
end
```

Pozor na fázu: `last_active_x_i` a `last_active_pixel_i` by mali byť request-phase signály, teda zarovnané s `pixel_req_i`. Podľa `video_timing_generator` už máš `last_active_x_req_o` a `last_active_pixel_req_o`, takže to je pripravené správne.

---

## 11. Stav vývoja po tejto verzii

### Hotové alebo veľmi dobrý smer

```text
+ oddelená video pipeline
+ RGB565 → RGB888 wrapper
+ hdmi_tx_core ako samostatný core
+ TMDS video encoder s DE gatingom
+ TMDS control encoder
+ TERC4 encoder
+ channel mux
+ video timing s hblank/vblank/blank_remaining
+ BCH/ECC modul
+ data_island_formatter modul
+ word-aligned PHY modul existuje
```

### Ešte problémové

```text
- aktuálna sada pravdepodobne neprejde kompiláciou kvôli nesediacim portom
- vga_hdmi_tx nepoužíva tmds_phy_ddr_aligned
- hdmi_tx_core nepoužíva data_island_formatter
- hdmi_period_scheduler nemá blank_remaining_i
- packet_scheduler je ešte byte-stream, nie packet-level arbiter
- data guard band CH0 je placeholder
- video preamble/guard band enum existuje, ale scheduler ho negeneruje
- BCH/ECC a data_island_formatter treba overiť testbenchmi
```

---

# Odporúčaný ďalší postup k plnému HDMI

## Fáza 1: zosúladiť kód, aby znovu kompiloval

Najprv nerieš audio. Oprav len integráciu.

Konkrétne:

```text
1. Pridať hblank_i/vblank_i/frame_start_i/blank_remaining_i do vga_hdmi_tx portov.
2. Prepojiť ich do hdmi_tx_core.
3. Pridať blank_remaining_i port do hdmi_period_scheduler.
4. V hdmi_period_scheduler použiť blank_remaining_i >= 44.
5. Vo vga_hdmi_tx nahradiť generic_serializer za tmds_phy_ddr_aligned.
```

Toto je nutný stabilizačný krok.

---

## Fáza 2: zapojiť `data_island_formatter` pre jeden AVI packet

Cieľ:

```text
InfoFrame builder → data_island_formatter → TERC4 → channel_mux
```

Dočasne ignoruj SPD, Audio InfoFrame, GCP, ACR a audio sample packets.

Urob len:

```text
raz za frame pošli AVI InfoFrame
```

V `hdmi_tx_core` vytvor:

```systemverilog
logic [7:0] hb [0:2];
logic [7:0] pb [0:27];
```

Pre AVI:

```systemverilog
assign hb[0] = hdr_avi[0];
assign hb[1] = hdr_avi[1];
assign hb[2] = hdr_avi[2];

always_comb begin
  pb = '{default: 8'h00};
  for (int i = 0; i < 28; i++) begin
    if (i < len_avi)
      pb[i] = pl_avi[i];
  end
end
```

Potom tento packet pošli do `data_island_formatter`.

Toto bude prvý reálny HDMI data island míľnik.

---

## Fáza 3: nahradiť `packet_scheduler` packet arbitrom

Keď AVI funguje, odstráň byte-stream scheduler.

Nový `packet_arbiter` má vyberať celé pakety:

```text
AVI packet
GCP packet
Audio InfoFrame packet
ACR packet
Audio Sample packet
```

Rozhranie:

```systemverilog
output logic [7:0] hb_o [0:2],
output logic [7:0] pb_o [0:27],
output logic       packet_valid_o,
input  logic       packet_accept_i
```

To je správny model pre `data_island_formatter`.

---

## Fáza 4: dokonči period scheduler

Doplniť:

```text
- blank_remaining_i
- packet_accept/data_island_start handshake
- neskôr video preamble + video guard band
```

Minimálne:

```systemverilog
packet_start_o = 1'b1
```

má znamenať:

```text
formatter latchuje práve vybraný hb/pb packet
```

a:

```systemverilog
packet_pop_o
```

má byť:

```text
advance_i pre data_island_formatter počas 32 payload symbolov
```

---

## Fáza 5: opraviť guard bands a preamble

V `hdmi_channel_mux` treba odstrániť placeholder:

```systemverilog
GB_DATA_0
```

a nahradiť ho dynamickou hodnotou podľa HS/VS.

Tiež treba zabezpečiť správne CTL hodnoty pre:

```text
data island preamble
video preamble
```

To znamená, že control encoder vstupy pre ch1/ch2 nemajú byť vždy `2'b00`.

---

## Fáza 6: overiť data island simuláciou

Pred monitorom určite sprav testbench:

```text
1. hdmi_bch_ecc test vector
2. data_island_formatter test
3. period_scheduler test s blank_remaining
4. hdmi_tx_core test: AVI packet sa objaví len počas blankingu
```

Bez toho bude debug na monitore veľmi ťažký.

---

## Fáza 7: až potom audio

Až keď funguje AVI InfoFrame cez skutočný data island, pridaj audio vrstvy:

```text
1. Audio InfoFrame builder
2. ACR N/CTS generator
3. Audio sample packetizer
4. audio FIFO / I2S receiver
5. packet arbiter priority medzi ACR/audio/AVI/GCP
```

Odporúčaná prvá audio konfigurácia:

```text
2-kanálové LPCM
48 kHz
16 alebo 24 bit
RGB 8-bit video
bez deep color
```

---

## Praktické poradie najbližších úprav

Najbližší commit by som spravil takto:

```text
Commit 1:
- zosúladiť porty hdmi_tx_core / hdmi_period_scheduler / vga_hdmi_tx
- nahradiť generic_serializer za tmds_phy_ddr_aligned
- ENABLE_DATA_ISLAND=0
- overiť čistý DVI obraz

Commit 2:
- hdmi_period_scheduler používa blank_remaining_i
- data_island_formatter pripojený do hdmi_tx_core
- zatiaľ len pevný AVI packet
- ENABLE_DATA_ISLAND=1 v simulácii

Commit 3:
- testbench pre BCH/ECC a data_island_formatter
- testbench pre period_scheduler

Commit 4:
- packet_arbiter namiesto packet_scheduler
- AVI raz za frame

Commit 5:
- GCP
- Audio InfoFrame
- ACR
- Audio sample packetizer
```

---

## Záver

Postupujete správnym smerom. Najväčší pokrok je, že už máte:

```text
hdmi_bch_ecc
data_island_formatter
blank_remaining vo video_timing_generator
tmds_phy_ddr_aligned
```

To sú presne bloky, ktoré treba na prechod z DVI-like výstupu na HDMI data islands.

Ale aktuálne je projekt v medzistave:

```text
nové HDMI bloky existujú,
ale hlavná cesta ich ešte nepoužíva správne.
```

Najbližší rozhodujúci krok je:

```text
zapojiť data_island_formatter do hdmi_tx_core
a nahradiť byte-stream packet_scheduler packet-level arbitrom.
```

A predtým ešte nutne zosúladiť porty a vrátiť `vga_hdmi_tx` na `tmds_phy_ddr_aligned`, nie `generic_serializer`.
