Refaktor video/VGA časti je **výrazne lepší než pôvodná verzia**. Vidno, že si správne oddelil:

```text id="5m7h6b"
video_timing_generator
video_stream_fifo_sync
video_stream_frame_aligner
vga_output_adapter
```

To je presne správny smer. Starý `vga_rgb565_stream` bol príliš veľký modul, ktorý robil timing, konzumoval stream, kontroloval chyby aj generoval VGA piny. Nová verzia je architektonicky čistejšia.

Ale v novej verzii máš ešte niekoľko dôležitých problémov, hlavne okolo **zarovnania pixel requestu, 1-taktovej latencie alignera a VGA výstupu**.

---

# 1. Celkový stav refaktoru

Nová zamýšľaná architektúra je:

```text id="48ymw3"
picture_gen_stream
        ↓
video_stream_fifo_sync
        ↓
video_stream_frame_aligner
        ↑
video_timing_generator
        ↓
vga_output_adapter
```

To je dobré.

Správne si oddelil:

```text id="qnw414"
timing       → video_timing_generator
buffer       → video_stream_fifo_sync
frame sync   → video_stream_frame_aligner
VGA piny     → vga_output_adapter
test pattern → picture_gen_stream
```

Toto je vhodné aj pre HDMI, pretože z toho vieš spraviť:

```text id="h0st3a"
video_timing_generator
        ↓
video_stream_frame_aligner
        ↓
RGB565 timed video
        ↓
rgb565_to_rgb888
        ↓
hdmi_tx_core
```

---

# 2. Najväčší problém: komentár o `pixel_req_o` nie je pravdivý

Vo `video_timing_generator.sv` máš komentár:

```systemverilog id="2y87r1"
// Outputs pixel_req_o (== de_o) one cycle ahead of the actual output
// so that stream aligners can fetch the pixel before it is needed.
```

Ale implementácia robí:

```systemverilog id="fuh59q"
de_o        <= de;
pixel_req_o <= de;
```

To znamená:

```text id="8pf2wl"
pixel_req_o a de_o sú v tom istom takte
```

Nie je tam žiadny „one cycle ahead“.

Toto je dôležité, pretože `video_stream_frame_aligner` má výstupný register:

```systemverilog id="z999va"
if (pixel_req_i) begin
  pixel_valid_o <= de_i;
  if (s_axis_valid_i && (state == ST_STREAM_FRAME))
    pixel_o <= s_axis_data_i;
  else
    pixel_o <= DEFAULT_COLOR;
end
```

Čiže pixel z alignera je platný **až o jeden takt po `pixel_req_i`**.

Ak `vga_output_adapter` dostane súčasne:

```text id="upwoos"
de_i z timing_generator
pixel_i z frame_aligner
```

tak nastane posun:

```text id="abfeea"
DE/HS/VS patria k aktuálnemu pixelu
pixel_o patrí k predchádzajúcemu requestu alebo ešte nie je pripravený
```

## Čo opraviť

Máš dve možnosti.

---

## Možnosť A — `pixel_req_o` má byť naozaj o 1 takt dopredu

V timing generátore vypočítaš `de_next` z budúceho počítadla a použiješ ho ako `pixel_req_o`.

Princíp:

```systemverilog id="1m9k9n"
logic [$clog2(H_TOTAL)-1:0] h_next;
logic [$clog2(V_TOTAL)-1:0] v_next;

always_comb begin
  h_next = h_cnt;
  v_next = v_cnt;

  if (h_cnt == H_TOTAL-1) begin
    h_next = '0;
    if (v_cnt == V_TOTAL-1)
      v_next = '0;
    else
      v_next = v_cnt + 1'b1;
  end else begin
    h_next = h_cnt + 1'b1;
  end
end

wire de_now  = (h_cnt  < H_ACTIVE) && (v_cnt  < V_ACTIVE);
wire de_next = (h_next < H_ACTIVE) && (v_next < V_ACTIVE);

always_ff @(posedge clk_i) begin
  de_o        <= de_now;
  pixel_req_o <= de_next;
end
```

Potom `pixel_req_o` naozaj povie:

```text id="iuqfdo"
v ďalšom takte budem potrebovať pixel
```

A aligner môže pripraviť pixel s jedným taktom predstihu.

---

## Možnosť B — nechaj `pixel_req_o == de_o`, ale oneskor timing signály

Ak aligner má 1-taktový výstupný register, oneskoríš aj `de/hs/vs` o 1 takt pred VGA adapterom:

```systemverilog id="y5i8fs"
logic de_d;
logic hs_d;
logic vs_d;

always_ff @(posedge clk_i) begin
  de_d <= de;
  hs_d <= hsync;
  vs_d <= vsync;
end
```

Potom:

```systemverilog id="n9ls6x"
vga_output_adapter u_vga (
  .pixel_i(pixel_from_aligner),
  .de_i   (de_d),
  .hsync_i(hs_d),
  .vsync_i(vs_d),
  ...
);
```

Toto je jednoduchšie. Ale potom `frame_start_i` do alignera tiež musí byť dobre zarovnaný voči requestu.

Moje odporúčanie: **pre video pipeline je lepšia možnosť A** — mať `pixel_req_o` ako request dopredu a `de_o/hsync_o/vsync_o` ako skutočný výstupný timing.

---

# 3. `frame_start_o` je tiež registrovaný v rovnakom takte ako `de_o`

V `video_timing_generator`:

```systemverilog id="emnnfu"
frame_start_o <= (h_cnt == 0) && (v_cnt == 0);
```

Ak `frame_start_o` používa `video_stream_frame_aligner` na prechod do `ST_STREAM_FRAME`, musí byť jasné, či znamená:

```text id="v9fj8g"
teraz sa práve zobrazuje prvý pixel
```

alebo:

```text id="u1zv3d"
v ďalšom takte bude treba prvý pixel
```

Teraz znamená skôr:

```text id="riqnmv"
v tomto takte sú timing signály pre prvý pixel
```

Ale aligner má výstupný register, takže keď v tom istom takte začne streamovať, pixel na výstupe bude až ďalší takt.

## Odporúčanie

Rozdeľ signály významovo:

```systemverilog id="z2huta"
frame_start_req_o   // request na prvý pixel, o takt skôr
frame_start_o       // skutočný prvý aktívny pixel na výstupe
```

alebo použi konzistentné oneskorenie všetkého.

Pre robustnú architektúru by som mal:

```text id="aecime"
pixel_req_o        → ide do alignera
frame_start_req_o  → ide do alignera
de_o/hsync_o/vsync_o → idú do výstupného adaptera
```

Ak aligner má 1-taktovú latenciu, requesty majú byť o 1 takt vpredu.

---

# 4. `video_stream_frame_aligner.sv` — dobrý smer, ale má chyby v handshake a kontrole metadát

FSM je dobrý nápad:

```systemverilog id="x49xst"
ST_SEARCH_SOF
ST_WAIT_FRAME_START
ST_STREAM_FRAME
ST_DROP_BROKEN_FRAME
```

Toto je lepšie než pôvodný `video_stream_frame_sync`.

Ale sú tam problémy.

---

## Problém A: `s_axis_ready_o = s_axis_valid_i`

V `ST_SEARCH_SOF` a `ST_DROP_BROKEN_FRAME` máš:

```systemverilog id="b3ggsx"
s_axis_ready_o = s_axis_valid_i;
```

Ready signál by spravidla nemal závisieť od valid. Nie je to nevyhnutne syntaktická chyba, ale je to zvláštne a zbytočné.

Lepšie:

```systemverilog id="6ixs5t"
s_axis_ready_o = 1'b1;
```

V stave, kde chceš stream zahadzovať, proste stále hovoríš upstreamu:

```text id="o8p580"
som pripravený čítať
```

Ak upstream nemá valid, nič sa nestane.

Oprava:

```systemverilog id="92frck"
ST_SEARCH_SOF: begin
  s_axis_ready_o = 1'b1;
  if (s_axis_valid_i && s_axis_sof_i)
    state_next = ST_WAIT_FRAME_START;
end
```

Ale pozor: týmto SOF pixel aj skonzumuješ. To je v tvojej novej architektúre vlastne v poriadku, lebo si už SOF detegoval a chceš čakať na najbližší timing frame. Len si musíš uvedomiť, že **tento SOF pixel je zahodený**.

Ak chceš SOF pixel ponechať ako prvý pixel frame, potrebuješ buffer/skid register. Viac nižšie.

---

## Problém B: v `ST_SEARCH_SOF` zahodíš SOF pixel

Aktuálne:

```systemverilog id="ogffex"
s_axis_ready_o = s_axis_valid_i;
if (s_axis_valid_i && s_axis_sof_i)
  state_next = ST_WAIT_FRAME_START;
```

Ak `s_axis_valid_i && s_axis_sof_i`, zároveň je `ready=1`, takže SOF pixel sa skonzumuje.

Potom v `ST_WAIT_FRAME_START` už na vstupe nie je prvý pixel frame, ale druhý pixel.

To znamená:

```text id="m6vtqg"
pri začiatku VGA frame zobrazíš pixel x=1 ako pixel x=0
celý obraz je posunutý o 1 pixel
EOF/EOL sa tiež posunú
```

Pôvodný `video_stream_frame_sync` toto riešil tak, že pri nájdení SOF nechal pixel stáť:

```systemverilog id="zdnewx"
s_axis_ready_o = 1'b0;
state_d = ST_WAIT_FRAME;
```

Nový aligner toto stratil.

## Čo opraviť

Máš dve možnosti.

### Možnosť 1 — SOF nečítať v `ST_SEARCH_SOF`

```systemverilog id="ddc4i1"
ST_SEARCH_SOF: begin
  if (s_axis_valid_i) begin
    if (s_axis_sof_i) begin
      s_axis_ready_o = 1'b0;   // nechaj SOF na výstupe FIFO
      state_next     = ST_WAIT_FRAME_START;
    end else begin
      s_axis_ready_o = 1'b1;   // zahadzuj staré pixely
    end
  end
end
```

Toto je jednoduché a pravdepodobne najlepšie.

### Možnosť 2 — SOF skonzumovať do lokálneho skid registra

To je robustnejšie, ale viac kódu:

```text id="fy9xrl"
keď nájdem SOF:
  ulož pixel do hold registra
  prechod do WAIT_FRAME_START
pri frame_start:
  najprv použi hold pixel
```

Pre začiatok odporúčam možnosť 1.

---

## Problém C: to isté v `ST_DROP_BROKEN_FRAME`

Aj tu:

```systemverilog id="yn9qa0"
s_axis_ready_o = s_axis_valid_i;
if (s_axis_valid_i && s_axis_sof_i)
  state_next = ST_WAIT_FRAME_START;
```

SOF pixel sa znova skonzumuje. Treba opraviť rovnako:

```systemverilog id="guumlj"
if (s_axis_valid_i && s_axis_sof_i) begin
  s_axis_ready_o = 1'b0;
  state_next     = ST_WAIT_FRAME_START;
end else begin
  s_axis_ready_o = 1'b1;
end
```

---

## Problém D: `pixel_o` používa `s_axis_data_i` bez ohľadu na handshake

V output registri:

```systemverilog id="b8us9e"
if (pixel_req_i) begin
  pixel_valid_o <= de_i;
  if (s_axis_valid_i && (state == ST_STREAM_FRAME))
    pixel_o <= s_axis_data_i;
  else
    pixel_o <= DEFAULT_COLOR;
end
```

Ale správne by si mal použiť pixel iba vtedy, keď nastane handshake:

```systemverilog id="52e2hu"
pixel_take = pixel_req_i && s_axis_valid_i && s_axis_ready_o;
```

Teraz je to síce takmer rovnaké, lebo v `ST_STREAM_FRAME` pri `pixel_req_i && s_axis_valid_i` nastavíš `ready=1`, ale po refaktore sa to môže rozísť. Lepšie je explicitne:

```systemverilog id="xjxxx4"
wire pixel_take = pixel_req_i &&
                  (state == ST_STREAM_FRAME) &&
                  s_axis_valid_i &&
                  s_axis_ready_o;
```

A potom:

```systemverilog id="jld4aq"
if (pixel_req_i) begin
  pixel_valid_o <= de_i;
  pixel_o       <= pixel_take ? s_axis_data_i : DEFAULT_COLOR;
end
```

---

## Problém E: `pixel_valid_o` sa nevynuluje mimo `pixel_req_i`

Teraz:

```systemverilog id="go3tek"
if (pixel_req_i) begin
  pixel_valid_o <= de_i;
  ...
end
```

Ak `pixel_req_i` spadne na 0, `pixel_valid_o` zostane na poslednej hodnote. Ak posledný aktívny pixel mal `de_i=1`, `pixel_valid_o` môže zostať 1 aj počas blankingu.

To je chyba, ak `pixel_valid_o` používa ďalší blok.

Oprava:

```systemverilog id="rv7t5d"
always_ff @(posedge clk_i) begin
  if (!rst_ni) begin
    pixel_valid_o <= 1'b0;
  end else begin
    pixel_valid_o <= pixel_req_i && de_i && (state == ST_STREAM_FRAME) && s_axis_valid_i;
    if (pixel_req_i) begin
      pixel_o <= pixel_take ? s_axis_data_i : DEFAULT_COLOR;
    end else if (!de_i) begin
      pixel_o <= DEFAULT_COLOR;
    end
  end
end
```

Ale keďže VGA adapter používa `de_i`, `pixel_valid_o` možno nepotrebuješ vôbec. Ak ho necháš, musí byť korektný.

---

## Problém F: nekontroluješ EOL/EOF voči timing pozícii

V starej verzii `vga_rgb565_stream` si kontroloval:

```text id="y7bv8f"
SOF na prvom pixeli
EOL na poslednom pixeli riadku
EOF na poslednom pixeli frame
```

Nový `video_stream_frame_aligner` zatiaľ kontroluje iba:

```systemverilog id="k12g49"
if (s_axis_sof_i && !frame_start_i)
```

Ale nekontroluje:

```text id="qfgitk"
EOL pri poslednom pixeli riadku
EOF pri poslednom pixeli frame
neočakávaný EOF skoro
chýbajúci EOL
chýbajúci EOF
```

To je regresia oproti starej verzii.

## Čo doplniť

Do alignera pridaj vstupy:

```systemverilog id="5od29p"
input logic line_last_pixel_i,
input logic frame_last_pixel_i
```

alebo z timing generatora:

```systemverilog id="ufemrx"
output logic last_active_x_o;
output logic last_active_pixel_o;
```

Potom v aligneri:

```systemverilog id="fwwdrp"
if (pixel_take) begin
  if (s_axis_eol_i != line_last_pixel_i)
    sync_error_o = 1'b1;

  if (s_axis_eof_i != frame_last_pixel_i)
    sync_error_o = 1'b1;

  if (s_axis_sof_i != frame_start_req_i)
    sync_error_o = 1'b1;
end
```

To je dôležité pre debug streamu.

---

# 5. `video_timing_generator.sv` — dobrý základ, ale potrebuje viac výstupov

Tento modul je dobrý. Počítadlá a sync generovanie sú správna filozofia.

Ale pre robustný video pipeline by som doplnil:

```systemverilog id="6hrdcw"
output logic hblank_o;
output logic vblank_o;
output logic blank_o;
output logic line_end_o;
output logic frame_end_o;
output logic last_active_x_o;
output logic last_active_pixel_o;
output logic [$clog2(H_TOTAL)-1:0] h_cnt_o;
output logic [$clog2(V_TOTAL)-1:0] v_cnt_o;
```

Prečo?

HDMI core bude potrebovať:

```text id="stikth"
hblank/vblank
line_start/frame_start
blank_remaining
last active pixel
```

A frame aligner bude potrebovať:

```text id="y24kpa"
posledný pixel riadku
posledný pixel frame
```

Momentálne máš iba:

```systemverilog id="7onvsm"
de_o
hsync_o
vsync_o
pixel_req_o
frame_start_o
line_start_o
x_o
y_o
```

To stačí pre základný VGA výstup, ale pre HDMI scheduler budeš chcieť viac.

---

# 6. `x_o` a `y_o` majú šírku iba podľa active rozlíšenia

```systemverilog id="7otm74"
output logic [$clog2(H_ACTIVE)-1:0] x_o,
output logic [$clog2(V_ACTIVE)-1:0] y_o
```

A mimo active dávaš:

```systemverilog id="ja0hyt"
x_o <= h_active ? h_cnt[...] : '0;
y_o <= v_active ? v_cnt[...] : '0;
```

To je použiteľné pre pixelové súradnice active oblasti.

Ale ak budeš chcieť analyzovať celý timing, potrebuješ aj plné počítadlá:

```systemverilog id="mp0oc9"
h_cnt_o
v_cnt_o
```

so šírkou:

```systemverilog id="ngf04x"
$clog2(H_TOTAL)
$clog2(V_TOTAL)
```

Odporúčanie:

```systemverilog id="ik4yg7"
x_o/y_o       → active pixel coordinates
h_cnt_o/v_cnt_o → full raster counters
```

---

# 7. `line_start_o` je iba počas active video

Teraz:

```systemverilog id="tlq2e6"
line_start_o <= h_active && (h_cnt == 0);
```

Keďže `h_cnt == 0` je zároveň active časť, je to vlastne začiatok aktívnej časti riadku.

To je OK, ale názov môže byť nejasný.

Možno by som rozlišoval:

```systemverilog id="u45a32"
active_line_start_o  // h_cnt==0 && v_active
raster_line_start_o  // h_cnt==0 vždy
```

Pre frame aligner chceš skôr:

```text id="6rlqj4"
active frame start
active line start
```

Pre HDMI scheduler môžeš chcieť aj raster line start.

---

# 8. `video_stream_fifo_sync.sv` — dobré zlepšenie, ale pozor na `DEPTH` a wrap

Nový FIFO je lepší než starý v tom, že umožňuje push pri plnom FIFO, ak zároveň popuješ:

```systemverilog id="r7hs5s"
assign s_axis_ready_o = (count < DEPTH) || pop;
```

To je správne.

Ale máš:

```systemverilog id="57xdym"
localparam int AW = $clog2(DEPTH);
logic [AW-1:0] wr_ptr;
logic [AW-1:0] rd_ptr;
```

A inkrementuješ:

```systemverilog id="lmocnz"
wr_ptr <= wr_ptr + 1;
rd_ptr <= rd_ptr + 1;
```

Toto funguje korektne iba ak `DEPTH` je mocnina dvoch.

Ak `DEPTH = 16`, OK.
Ak `DEPTH = 1000`, pointer pôjde až po 1023 a bude indexovať mimo poľa `data_mem[0:999]`.

## Čo opraviť

Buď vynútiť power-of-two:

```systemverilog id="7zi9n3"
initial begin
  assert ((DEPTH & (DEPTH-1)) == 0)
    else $error("DEPTH must be power of two");
end
```

alebo použiť wrap funkciu ako v starej verzii:

```systemverilog id="e0b4j6"
function automatic logic [AW-1:0] ptr_next(input logic [AW-1:0] ptr);
  if (ptr == DEPTH-1)
    return '0;
  else
    return ptr + 1'b1;
endfunction
```

A potom:

```systemverilog id="917e1s"
wr_ptr <= ptr_next(wr_ptr);
rd_ptr <= ptr_next(rd_ptr);
```

Odporúčam druhú možnosť.

---

# 9. `video_stream_fifo_sync` nemá overflow/underflow status

Starý FIFO mal:

```systemverilog id="2vk3i4"
overflow_o
underflow_o
```

Nový FIFO má iba:

```systemverilog id="icdk42"
fill_o
```

To je čistejšie, ale pre debug na FPGA by som ponechal aspoň voliteľné sticky statusy:

```systemverilog id="px88cy"
output logic overflow_o;
output logic underflow_o;
```

Alebo aspoň:

```systemverilog id="kp4447"
output logic overflow_sticky_o;
output logic underflow_sticky_o;
```

Nie je to nutné pre funkciu, ale veľmi užitočné pri ladení.

---

# 10. `video_stream_fifo_sync` má kombinačný read z pamäte

```systemverilog id="da5dam"
assign m_axis_data_o = data_mem[rd_ptr];
```

Pre malý FIFO v LUT RAM je to OK.

Pre väčší FIFO alebo inferenciu BRAM budeš chcieť synchrónny read port a výstupný register. Teraz je to skôr:

```text id="1h8vu0"
malý LUT FIFO
```

Pre veľké buffre by som ho nepoužíval.

Odporúčanie pre názov/komentár:

```text id="yoah8b"
video_stream_fifo_sync_lut
```

alebo doplniť parameter:

```systemverilog id="12eptp"
parameter bit REGISTER_OUTPUT = 0
```

---

# 11. `vga_output_adapter.sv` je dobrý

Tento modul je pekne jednoduchý:

```systemverilog id="vmskdg"
vga_r_o <= de_i ? pixel_i.red : 5'b0;
vga_g_o <= de_i ? pixel_i.grn : 6'b0;
vga_b_o <= de_i ? pixel_i.blu : 5'b0;
vga_hs_o <= hsync_i;
vga_vs_o <= vsync_i;
```

To je presne to, čo má output adapter robiť.

Jediné upozornenie:

## Reset HS/VS by mal rešpektovať polaritu

Teraz resetuješ:

```systemverilog id="x6ax79"
vga_hs_o <= 1'b0;
vga_vs_o <= 1'b0;
```

Ak máš aktívne nízku synchronizáciu, neaktívny stav je `1`. Pre čistotu by som dal parametre:

```systemverilog id="ne6xyw"
parameter bit HSYNC_POL = 1'b1,
parameter bit VSYNC_POL = 1'b1
```

a reset:

```systemverilog id="3wtcf3"
vga_hs_o <= ~HSYNC_POL;
vga_vs_o <= ~VSYNC_POL;
```

Ale ak už `hsync_i/vsync_i` prichádzajú registrované z timing generatora, reset tu nie je kritický.

---

# 12. `picture_gen_stream.sv` — stále má pár problémov

Tento modul je použiteľný, ale sú tam drobnosti.

## Problém A: enum hodnoty sú natvrdo `3'd`

Máš:

```systemverilog id="ois4qv"
typedef enum logic [MODE_WIDTH-1:0] {
    MODE_CHECKER_SMALL = 3'd0,
    ...
    MODE_MOVING_BAR    = 3'd7
} mode_e;
```

Ak zmeníš `MAX_MODES`, šírka enumu sa zmení, ale hodnoty ostanú `3'd`.

Lepšie:

```systemverilog id="icbo7u"
typedef enum logic [MODE_WIDTH-1:0] {
    MODE_CHECKER_SMALL,
    MODE_CHECKER_LARGE,
    MODE_H_GRADIENT,
    MODE_V_GRADIENT,
    MODE_COLOR_BARS,
    MODE_CROSSHAIR,
    MODE_DIAG_SCROLL,
    MODE_MOVING_BAR
} mode_e;
```

Alebo zrušiť `MAX_MODES` parameter a dať:

```systemverilog id="h2rgjr"
localparam int MODE_WIDTH = 3;
```

---

## Problém B: `MODE_MOVING_BAR` má šírkový problém

```systemverilog id="kby45u"
if (((x_q + X_WIDTH'(scroll_offset_q)) & 8'h3F) < 16)
```

Ak `X_WIDTH` nie je 8, maska `8'h3F` môže spôsobiť šírkové warningy alebo nechcené rozšírenia.

Čistejšie:

```systemverilog id="3vii3a"
logic [X_WIDTH-1:0] x_scroll;
x_scroll = x_q + X_WIDTH'(scroll_offset_q);

if (x_scroll[5:0] < 6'd16)
  data_next = RED;
else
  data_next = BLACK;
```

Ale to platí iba ak `X_WIDTH >= 6`. Bezpečnejšie:

```systemverilog id="6zkrb0"
logic [15:0] x_scroll;
x_scroll = 16'(x_q) + 16'(scroll_offset_q);

if (x_scroll[5:0] < 6'd16)
```

---

## Problém C: komentáre obsahujú zvyšky `[cite: 4]`

Napríklad:

```systemverilog id="ye2i4t"
// Sekvenčná logika pre generovanie súradníc a animáciu[cite: 4]
```

To je asi z importu dokumentácie. Odstránil by som to zo zdrojového kódu.

---

# 13. `video_pkg.sv` je zatiaľ príliš malý

Je OK, ale po refaktore by som ho rozšíril.

Dnes obsahuje iba `rgb565_t` a farby. Pridal by som typy:

```systemverilog id="6wbi1p"
typedef struct packed {
  logic [7:0] red;
  logic [7:0] grn;
  logic [7:0] blu;
} rgb888_t;
```

A možno stream metadáta:

```systemverilog id="8w0fy2"
typedef struct packed {
  rgb565_t pixel;
  logic    sof;
  logic    eol;
  logic    eof;
} video_stream_rgb565_t;
```

A timing config:

```systemverilog id="jeo9k7"
typedef struct packed {
  logic [15:0] h_active;
  logic [15:0] h_fp;
  logic [15:0] h_sync;
  logic [15:0] h_bp;
  logic [15:0] v_active;
  logic [15:0] v_fp;
  logic [15:0] v_sync;
  logic [15:0] v_bp;
  logic        hsync_pol;
  logic        vsync_pol;
} video_timing_cfg_t;
```

Nie je to nutné hneď, ale pre budúce projekty to pomôže.

---

# 14. Staré moduly by som už nepoužíval v hlavnej ceste

Tieto súbory máš stále:

```text id="xboxn2"
vga_rgb565_stream.sv
video_stream_fifo.sv
video_stream_frame_sync.sv
```

Po refaktore by som ich nepoužíval v novej topológii.

Odporúčam:

```text id="gfpqu9"
vga_rgb565_stream.sv        → legacy alebo odstrániť
video_stream_fifo.sv        → legacy, nahradený video_stream_fifo_sync.sv
video_stream_frame_sync.sv  → legacy, nahradený video_stream_frame_aligner.sv
```

Aby nevznikol zmätok, premenuj ich napríklad:

```text id="m0khzd"
legacy/vga_rgb565_stream_legacy.sv
legacy/video_stream_fifo_legacy.sv
legacy/video_stream_frame_sync_legacy.sv
```

---

# 15. Navrhovaná opravená väzba modulov

Pre VGA výstup:

```text id="8pxsyj"
video_timing_generator
    ├── pixel_req_o / frame_start_req_o  ──▶ video_stream_frame_aligner
    └── de_o / hsync_o / vsync_o ─────────▶ delay podľa latencie alignera
                                             │
picture_gen_stream → fifo_sync → aligner ───┘
                                             ↓
                                     vga_output_adapter
```

Ak aligner zostane 1-taktový, musíš mať buď:

```text id="t8ue94"
pixel_req o 1 takt pred de
```

alebo:

```text id="pr01ll"
oneskoriť de/hs/vs o 1 takt
```

Bez toho bude obraz posunutý.

---

# 16. Prioritné opravy

## 1. Opraviť `video_stream_frame_aligner`, aby nezahadzoval SOF pixel

Toto je najväčšia funkčná chyba.

Oprava v `ST_SEARCH_SOF`:

```systemverilog id="mitpqq"
if (s_axis_valid_i) begin
  if (s_axis_sof_i) begin
    s_axis_ready_o = 1'b0;
    state_next     = ST_WAIT_FRAME_START;
  end else begin
    s_axis_ready_o = 1'b1;
  end
end
```

Rovnako v `ST_DROP_BROKEN_FRAME`.

---

## 2. Opraviť význam `pixel_req_o`

Buď ho spraviť naozaj o 1 takt dopredu, alebo oneskoriť timing signály.

Teraz je komentár a implementácia v rozpore.

---

## 3. Opraviť `pixel_valid_o`

Nesmie držať starú hodnotu mimo active/request.

Minimálne:

```systemverilog id="5x8s6a"
pixel_valid_o <= pixel_req_i && de_i && (state == ST_STREAM_FRAME) && s_axis_valid_i;
```

---

## 4. Opraviť FIFO pointer wrap

Ak chceš podporovať ľubovoľné `DEPTH`, pridaj `ptr_next`.

---

## 5. Doplniť EOL/EOF kontrolu do alignera

Pridaj `line_last_pixel_i` a `frame_last_pixel_i`.

---

# 17. Hodnotenie jednotlivých nových modulov

| Modul                        |                            Stav | Komentár                                                     |
| ---------------------------- | ------------------------------: | ------------------------------------------------------------ |
| `video_timing_generator`     |                    dobrý základ | treba opraviť/ujasniť `pixel_req_o` a doplniť timing výstupy |
| `video_stream_fifo_sync`     |                      použiteľný | pozor na `DEPTH` mimo power-of-two                           |
| `video_stream_frame_aligner` | dobrý koncept, funkčne rizikový | zahadzuje SOF pixel, chýba EOL/EOF kontrola                  |
| `vga_output_adapter`         |                           dobrý | iba reset HS/VS podľa polarity                               |
| `picture_gen_stream`         |                      použiteľný | enum šírky, drobné šírkové veci, cleanup komentárov          |
| `video_pkg`                  |                    OK, ale malé | doplniť `rgb888_t`, timing config, stream typy               |
| staré moduly                 |                          legacy | presunúť mimo hlavnej cesty                                  |

---

# 18. Najdôležitejšie zhrnutie

Refaktor je správny:

```text id="ag2spq"
timing generator
+ stream aligner
+ FIFO
+ VGA output adapter
```

je oveľa lepšia architektúra než pôvodný monolitický `vga_rgb565_stream`.

Ale musíš opraviť dve veci, inak môže byť obraz posunutý:

```text id="g8ms5m"
1. frame_aligner nesmie skonzumovať SOF pixel pri hľadaní SOF
2. pixel_req/de/pixel_o musia byť latenciuovo zarovnané
```

Potom bude táto video časť veľmi dobrý základ pre VGA aj HDMI.
