Áno — podľa aktuálnej sady súborov je refaktor už **vo veľkej miere v súlade s návrhom správneho designu**, hlavne v DVI-compatible video režime. Už máš oddelené vrstvy:

```text
video source / stream
    ↓
video timing + frame aligner
    ↓
VGA alebo HDMI adapter
    ↓
hdmi_tx_core
    ↓
samostatný TMDS PHY
```

To je presne smer, ktorý sme navrhovali. Zároveň však ešte nie je hotový „plný HDMI“ s data islands, InfoFrames a audio. To je zatiaľ skôr kostra.

---

## 1. Čo je už správne navrhnuté

### `vga_hdmi_tx.sv`

Toto je teraz správne zapuzdrené.

Aktuálna cesta je:

```text
RGB565 + HS/VS/DE
    ↓
RGB565 → RGB888
    ↓
hdmi_tx_core
    ↓
tmds_phy_ddr_aligned
```

To je správne. `vga_hdmi_tx` už nerobí starú chybu typu:

```text
VGA → starý hdmi_tx_top → starý serializer
```

Naopak, používa:

```systemverilog
hdmi_tx_core #(
  .ENABLE_DATA_ISLAND(ENABLE_DATA_ISLAND)
) u_core (...);
```

a potom:

```systemverilog
tmds_phy_ddr_aligned u_phy (...);
```

Toto je dobré delenie:

```text
hdmi_tx_core = logický HDMI/TMDS core
tmds_phy_ddr_aligned = fyzická serializačná vrstva
```

---

### `tmds_phy_ddr_aligned.sv`

Toto je veľký posun oproti pôvodnému `generic_serializer`.

Pôvodne bol problém:

```text
load_toggle cez CDC
→ nezaručené zarovnanie na 10-bitové TMDS slovo
```

Teraz máš samostatný PHY s počítadlom:

```systemverilog
pair_cnt <= (pair_cnt == 3'd4) ? 3'd0 : pair_cnt + 3'd1;
```

a 10-bitové slovo sa načítava pri:

```systemverilog
else if (pair_cnt == 3'd4) begin
  sr_ch0 <= ch0_i;
  sr_ch1 <= ch1_i;
  sr_ch2 <= ch2_i;
  sr_clk <= clk_ch_i;
end
```

Toto je už filozoficky správne:

```text
5× rýchly clock × DDR 2 bity = 10 bitov na pixel
```

Teda serializér je teraz word-aligned, nie všeobecný CDC serializér.

Pozor však na jednu vec: `pair_cnt` musí byť fázovo deterministicky zarovnaný voči `pix_clk_i`. V komentári predpokladáš, že `pix_clk_i` a `clk_x_i` sú PLL co-generated a majú 0° offset. To je správny predpoklad, ale v reálnom FPGA treba zabezpečiť aj **deterministické uvoľnenie resetu** alebo fázové zarovnanie počítadla. Inak sa môže stať, že `pair_cnt == 4` zachytí TMDS slová príliš blízko hrany `pix_clk_i`.

Odporúčanie:

```text
- rst_ni uvoľňovať až po PLL locked
- reset synchronizovať do clk_x_i aj pix_clk_i
- v constraintoch explicitne riešiť pix_clk → clk_x_i multicycle alebo generated clocks
```

Modul `pix_clk_i` zatiaľ vnútri nepoužívaš; to je v poriadku funkčne, ale nástroj ho môže hlásiť ako unused. Buď ho použi na synchronizované zarovnanie, alebo ho odstráň z PHY portu, ak ho nechceš používať.

---

### `video_timing_generator.sv`

Tento modul je teraz veľmi dobre navrhnutý.

Pozitívne:

```text
+ timing je cez počítadlá, nie veľký FSM
+ má DE, HSYNC, VSYNC
+ má look-ahead pixel_req_o
+ má frame_start_o a line_start_o
+ má hblank/vblank
+ má last_active_x_o a last_active_pixel_o
+ má celé h_cnt_o/v_cnt_o
```

Toto je presne správny základ pre VGA aj HDMI.

Veľmi dobrá oprava je:

```systemverilog
pixel_req_o   <= de_next;
frame_start_o <= frame_start_next;
line_start_o  <= line_start_next;
```

Tým pádom `pixel_req_o` naozaj príde o jeden takt skôr než `de_o`. To sedí s 1-taktovou latenciou `video_stream_frame_aligner`.

Tento modul je v súlade s odporúčaným designom.

---

### `video_stream_frame_aligner.sv`

Aj tento modul je architektonicky správne oddelený.

Pozitívne:

```text
+ má samostatný FSM pre SOF/frame synchronizáciu
+ nezahadzuje SOF pixel
+ má WAIT_FRAME_START stav
+ má DROP_BROKEN_FRAME stav
+ má sticky underflow flag
+ výstupný pixel je registrovaný
```

Dôležité je, že v `ST_SEARCH_SOF` máš:

```systemverilog
if (s_axis_sof_i) begin
  s_axis_ready_o = 1'b0;   // leave SOF in FIFO
  state_next     = ST_WAIT_FRAME_START;
end
```

Toto je správne. SOF pixel zostane stáť vo FIFO a načíta sa až v správnom čase.

Toto bola jedna z kľúčových vecí, ktorú bolo treba opraviť.

---

### `vga_output_adapter.sv`

Tento modul je správne minimalistický:

```systemverilog
vga_r_o  <= de_i ? pixel_i.red : 5'b0;
vga_g_o  <= de_i ? pixel_i.grn : 6'b0;
vga_b_o  <= de_i ? pixel_i.blu : 5'b0;
vga_hs_o <= hsync_i;
vga_vs_o <= vsync_i;
```

Presne takto má vyzerať output adapter. Nerobí timing, nerobí FIFO, nerobí stream synchronizáciu.

To je v súlade so správnym delením.

---

## 2. HDMI core: dobrý pre DVI-compatible režim, nie ešte pre plné HDMI

### `hdmi_tx_core.sv`

Architektúra je už správna:

```text
input register
    ↓
period scheduler
    ↓
TMDS video encoder
TMDS control encoder
TERC4 path
    ↓
channel mux
    ↓
3× 10-bit TMDS word
```

Pre režim:

```systemverilog
ENABLE_DATA_ISLAND = 0
```

je to dobrý základ pre DVI-compatible HDMI výstup.

Najdôležitejšie: `tmds_video_encoder` už dostáva `de_i`, takže vie resetovať running disparity počas blankingu:

```systemverilog
.de_i(de_r)
```

To je správne.

---

## 3. Čo ešte nie je úplne v súlade s finálnym HDMI návrhom

### A. Data-island cesta je zatiaľ zjednodušená

V `hdmi_tx_core` máš zatiaľ:

```systemverilog
pkt_byte[3:0] → TERC4 ch0
pkt_byte[7:4] → TERC4 ch1
4'h0          → TERC4 ch2
```

To je vhodné ako test TERC4 cesty, ale nie ako skutočný HDMI data island.

Pre plné HDMI stále chýba:

```text
data_island_formatter
    - packet header layout
    - subpacket mapping
    - BCH/ECC
    - 3× 4-bit nibble pre CH0/CH1/CH2
```

Teda aktuálny stav:

```text
DVI-compatible video: áno, dobrý smer
plné HDMI data islands: ešte nie
```

Odporúčanie: zatiaľ držať:

```systemverilog
ENABLE_DATA_ISLAND = 0
```

kým nebude stabilný obraz.

---

### B. `hdmi_period_scheduler` nevie, či sa data island zmestí do blankingu

Scheduler má fixnú sekvenciu:

```text
8 preamble + 2 guard + 32 payload + 2 guard = 44 pixel clockov
```

Spúšťa ju pri:

```systemverilog
hblank_i && packet_pending_i
```

Ale nekontroluje, koľko blanking času ešte zostáva.

Pre plné HDMI budeš potrebovať vstup napríklad:

```systemverilog
input logic [15:0] blank_remaining_i;
```

a podmienku:

```systemverilog
if (hblank_i && packet_pending_i && blank_remaining_i >= 16'd44)
```

Bez toho môže data island začať príliš neskoro v blankingu a zasiahnuť do active video.

Pre `ENABLE_DATA_ISLAND=0` to nevadí.

---

### C. `vblank` v `hdmi_tx_core` je zatiaľ zjednodušený nesprávne

V `hdmi_tx_core` máš:

```systemverilog
wire vblank = vsync_r;
wire hblank = ~de_r && ~vblank;
```

Toto nie je všeobecne správne.

`vsync` je iba synchronizačný pulz. `vblank` je celý vertikálny blanking interval. Navyše sync polarita môže byť aktívne nízka.

Pre DVI-only režim je to menej dôležité, ale pre HDMI data islands, InfoFrames a audio to treba prerobiť.

Keďže `video_timing_generator` už vie generovať:

```text
hblank_o
vblank_o
h_cnt_o
v_cnt_o
last_active_pixel_o
```

neskôr by som rozšíril `hdmi_tx_core` vstup o:

```systemverilog
input logic hblank_i,
input logic vblank_i,
input logic frame_start_i,
input logic line_start_i,
input logic [15:0] blank_remaining_i
```

a nepokúšal sa `vblank` hádať z `vsync`.

---

## 4. `packet_scheduler.sv`: lepší, ale stále nie finálny HDMI packetizer

Dobré veci:

```text
+ má consume_i handshake
+ neposúva byte bez toho, aby ho period scheduler spotreboval
+ vie preskočiť AVI/SPD/Audio podľa dĺžky
+ nepoužíva int pre index
```

To je v súlade s návrhom.

Ale stále je to byte scheduler, nie HDMI data-island formatter.

Napríklad GCP je tu reprezentovaný iba ako:

```systemverilog
GCP_HEADER = 8'h03;
GCP_BYTE0  = 8'h00;
```

Skutočný HDMI packet prenos cez data islands má presnejší formát, nie iba lineárny byte stream do TERC4.

Pre ďalšiu fázu by som tento modul nechal ako „packet byte source“ a medzi neho a TERC4 pridal:

```text
data_island_formatter
```

---

## 5. `tmds_video_encoder.sv`: filozofia správna, ale algoritmus treba overiť testbenchom

Pozitívne:

```text
+ samostatný modul
+ pipeline
+ de_i resetuje running disparity
+ jasná konvencia q_m[8]: 1 = XOR, 0 = XNOR
+ latencia je dokumentovaná
```

To je správny design.

K samotnému TMDS algoritmu: aktuálna verzia vyzerá konzistentnejšie než staršie verzie. Napríklad pri `rd == 0 || neutral` robíš:

```systemverilog
invert = ~q_m_r[8];
```

čo pri tvojej konvencii `q_m[8] = 1 pre XOR` dáva:

```text
XOR path  → neinvertovať
XNOR path → invertovať
```

To zodpovedá bežnej interpretácii TMDS algoritmu.

Napriek tomu by som tento modul určite overil referenčným testbenchom. TMDS encoder je kritická časť. Mal by si overiť:

```text
- všetkých 256 vstupných bajtov
- DE prechody 0→1 a 1→0
- reset running disparity počas blankingu
- porovnanie s referenčnou implementáciou
```

Architektonicky je modul správny. Funkčne ho ešte treba verifikovať.

---

## 6. `hdmi_channel_mux.sv`: dobré delenie, ale guard bandy sú stále placeholder pre plné HDMI

Mux je správne samostatný a registrovaný:

```text
video/control/data → channel mux → TMDS words
```

To je správne.

Pre DVI režim používa prakticky len:

```text
HDMI_PERIOD_VIDEO
HDMI_PERIOD_CONTROL
```

a to je v poriadku.

Ale pre plné HDMI sú tieto časti ešte zjednodušené:

```systemverilog
GB_VIDEO
GB_DATA_0
GB_DATA_N
```

a `HDMI_PERIOD_DATA_PREAMBLE` iba prepúšťa control symboly.

Pre finálne HDMI bude treba presne nastaviť control/preamble/guard-band podľa špecifikácie. Zatiaľ je to OK ako kostra.

---

## 7. Video stream časť je už veľmi blízko správnemu designu

### `video_stream_fifo_sync.sv`

FIFO je už lepší:

```text
+ podporuje push+pop pri full stave
+ má SOF/EOL/EOF metadáta
+ má wrap aj pre non-power-of-two DEPTH
```

Jediná technická poznámka:

```systemverilog
localparam logic [AW-1:0] DEPTH_LAST = AW'(DEPTH - 1);
```

Niektoré syntézne nástroje môžu byť citlivé na tento cast. Ak by Quartus/Verilator protestoval, bezpečnejšie je:

```systemverilog
localparam logic [AW-1:0] DEPTH_LAST = DEPTH - 1;
```

alebo explicitnejší lokálny prepočet.

Inak je modul v poriadku ako malý synchrónny LUT FIFO.

---

### `video_stream_frame_aligner.sv`

Architektúra je správna, ale ešte by som doplnil využitie signálov:

```systemverilog
last_active_x_i
last_active_pixel_i
s_axis_eol_i
s_axis_eof_i
```

Momentálne sú porty pripravené, ale kontrola EOL/EOF ešte nie je reálne použitá.

Odporúčanie pri `pixel_take`:

```systemverilog
if (pixel_take) begin
  if (s_axis_eol_i != last_active_x_i)
    sync_error_o = 1'b1;

  if (s_axis_eof_i != last_active_pixel_i)
    sync_error_o = 1'b1;
end
```

Pozor však na fázu signálov: `pixel_req_i` je o takt pred `de_i`, takže aj `last_active_x_i` / `last_active_pixel_i` musia byť fázovo zarovnané s tým momentom, v ktorom reálne berieš pixel zo streamu.

Aktuálne je aligner použiteľný, ale EOL/EOF kontrola je ešte nedokončená.

---

### `pixel_loaded_o`

Aktuálne máš:

```systemverilog
pixel_loaded_o <= pixel_take && de_i;
```

Keďže `pixel_req_i` je look-ahead a `de_i` je o takt neskôr, tento signál môže byť významovo trochu mätúci.

Funkčne to nevadí, ak ho nepoužívaš ako hlavné `valid`. Ale odporúčal by som ho premenovať alebo jasne definovať:

```text
pixel_loaded_o = bol načítaný reálny pixel zo streamu
```

alebo

```text
pixel_valid_o = pixel na výstupe je platný v aktuálnom DE cykle
```

Teraz je to niečo medzi tým.

---

## 8. `picture_gen_stream.sv`

Tento modul je už v poriadku ako testovací zdroj.

Pozitívne:

```text
+ valid/ready handshake je správne
+ x/y sa posúvajú iba pri handshake
+ SOF/EOL/EOF sú generované z x/y
+ enum už nemá pevné 3'd hodnoty
+ moving bar šírkový problém je opravený cez 16-bit x_scroll
```

Toto je vhodný demo/test pattern generator. Len by som ho nechal v `generators/`, nie v core knižnici.

---

## 9. Čo je už v súlade s navrhnutým správnym designom

Áno, tieto časti sú už v súlade:

```text
+ oddelený video_timing_generator
+ oddelený video_stream_frame_aligner
+ oddelený video_stream_fifo_sync
+ jednoduchý vga_output_adapter
+ vga_hdmi_tx ako wrapper, nie ako core
+ hdmi_tx_core oddelený od PHY
+ tmds_phy_ddr_aligned ako samostatný PHY modul
+ tmds_video_encoder oddelený od control encoderu
+ tmds_control_encoder samostatný
+ terc4_encoder samostatný
+ hdmi_channel_mux samostatný
+ infoframe_builder má správnejší checksum/payload model
```

Toto je veľmi dobrý stav pre ďalší vývoj.

---

## 10. Čo ešte nie je úplne v súlade

Nie sú to už základné architektonické chyby, skôr nedokončené vrstvy:

```text
- data island cesta ešte nie je štandardovo kompletná
- chýba data_island_formatter
- hdmi_period_scheduler nevie blank_remaining
- hdmi_tx_core si vblank odvodzuje z vsync
- packet_scheduler je byte scheduler, nie HDMI packet formatter
- channel_mux guard band/preamble hodnoty treba overiť pre plné HDMI
- tmds_video_encoder treba overiť referenčným testbenchom
- tmds_phy_ddr_aligned potrebuje dôsledné reset/clock phase constraints
- frame_aligner má pripravené EOL/EOF porty, ale ešte ich plne nekontroluje
```

---

## 11. Praktické hodnotenie

Pre cieľ:

```text
DVI-compatible HDMI video bez audio a bez InfoFrames
```

je refaktor už **takmer v správnom dizajne**. Najväčšie riziko je teraz už hlavne fyzická časť:

```text
tmds_phy_ddr_aligned
clock phase
reset release
IO primitive ddio_out
constraints
```

Pre cieľ:

```text
plné HDMI s InfoFrame/audio/data islands
```

je architektúra pripravená, ale implementácia ešte nie je kompletná. Tam ešte treba:

```text
data_island_formatter
BCH/ECC
presný preamble/guard band
blank_remaining scheduler
ACR/audio packetizer
skutočné HDMI packet mapping
```

---

## 12. Odporúčané ďalšie kroky

Priorita by mala byť:

```text
1. Držať ENABLE_DATA_ISLAND = 0.
2. Otestovať DVI video cestu na monitore.
3. Overiť tmds_video_encoder testbenchom.
4. Doladiť tmds_phy_ddr_aligned reset/phase constraints.
5. Až potom riešiť data_island_formatter.
6. Potom AVI InfoFrame.
7. Nakoniec audio.
```

---

## Záver

Áno, tento refaktor je už **vo veľkej miere v súlade so správnym návrhom**.

Najväčšie pôvodné problémy sú odstránené:

```text
monolitický VGA modul → rozdelený video pipeline
starý hdmi_tx_top → nahradený hdmi_tx_core
CDC serializer → nahradený word-aligned TMDS PHY
zmiešaný video/control/data encoder → rozdelené encodery a mux
SOF pixel drop → opravené
pixel_req latency → opravené
InfoFrame off-by-one → opravené
```

Zostáva hlavne rozdiel medzi:

```text
správna DVI/TMDS video architektúra
```

a

```text
plne štandardný HDMI s data islands/audio
```

Na prvé si už veľmi blízko. Na druhé máš dobrú kostru, ale ešte chýba formatter a presné HDMI packet vrstvy.
