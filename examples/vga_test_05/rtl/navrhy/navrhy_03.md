Máš pravdu. Teraz som prešiel **aktuálne súbory priamo z `/mnt/data`**. Opravujem teda aj svoje predchádzajúce tvrdenia: v tejto verzii už **`vga_hdmi_tx.sv` naozaj používa `hdmi_tx_core`**, `generic_serializer` už má `logic load_toggle`, `video_timing_generator` už má look-ahead `pixel_req_o` a `video_stream_frame_aligner` už nezahadzuje SOF pixel. Tieto veci som predtým nesprávne hodnotil podľa staršej verzie.

Nižšie je analýza podľa aktuálne nahratých súborov.

---

# 1. Čo je už opravené a je dobré

## `vga_hdmi_tx.sv` už používa novú architektúru

Aktuálne tam máš:

```systemverilog
hdmi_tx_core #(
  .ENABLE_DATA_ISLAND(ENABLE_DATA_ISLAND)
) u_core (
  ...
);
```

na riadkoch `48–67`.

To je správne. Už tam nie je starý `hdmi_tx_top`. Architektúra teraz vyzerá takto:

```text
RGB565 VGA-style vstup
    ↓
RGB565 → RGB888
    ↓
hdmi_tx_core
    ↓
generic_serializer
    ↓
hdmi_p_o
```

Toto je výrazný posun správnym smerom.

---

## `generic_serializer.sv` už nemá chybu `wire load_toggle`

Aktuálne máš:

```systemverilog
logic load_toggle;
```

na riadku `71`.

To je opravené. Predchádzajúca syntaktická chyba `wire` v `always_ff` už neplatí.

---

## `video_timing_generator.sv` už má skutočný look-ahead `pixel_req_o`

Teraz tam naozaj počítaš budúce počítadlá:

```systemverilog
h_next
v_next
de_next
frame_start_next
line_start_next
```

riadky `84–100`, a potom:

```systemverilog
pixel_req_o   <= de_next;
frame_start_o <= frame_start_next;
line_start_o  <= line_start_next;
```

riadky `123–125`.

Toto je správne. `pixel_req_o` je teraz naozaj o jeden takt pred `de_o`, čo sedí s 1-taktovou latenciou `video_stream_frame_aligner`.

---

## `video_stream_frame_aligner.sv` už nezahadzuje SOF pixel

V stave `ST_SEARCH_SOF` máš:

```systemverilog
if (s_axis_sof_i) begin
  s_axis_ready_o = 1'b0;   // leave SOF in FIFO
  state_next     = ST_WAIT_FRAME_START;
end
```

riadky `74–78`.

To je správna oprava. SOF pixel zostane na čele FIFO a čaká na `frame_start_i`.

Rovnako to máš opravené aj v `ST_DROP_BROKEN_FRAME`, riadky `114–118`.

---

## `infoframe_builder.sv` má opravený payload/checksum model

Teraz máš správnu konvenciu:

```text
payload_o[0]    = PB0 checksum
payload_o[1..N] = PB1..PBN
payload_len_o   = N + 1
```

Napríklad pre AVI:

```systemverilog
payload_len_o = int'(AVI_LENGTH) + 1;
```

riadok `60`.

Checksum sa počíta po naplnení payloadu:

```systemverilog
payload_o[0] = calc_checksum(header_o, payload_o, payload_len_o);
```

riadok `111`.

Toto je dobrá oprava predchádzajúcej off-by-one chyby.

---

# 2. Najkritickejší problém zostáva: `generic_serializer` nie je vhodný TMDS PHY

Aj keď je syntakticky lepší, architektonicky má stále zásadný problém.

V `generic_serializer.sv` robíš:

```systemverilog
load_toggle <= ~load_toggle;
```

v pixel clock doméne, riadok `89`, potom ho synchronizuješ do `clk_x_i`:

```systemverilog
load_sync <= {load_sync[0], load_toggle};
wire load_pulse = load_sync[1] ^ load_sync[0];
```

riadky `97–104`.

Potom pri `load_pulse` načítaš nové TMDS slovo:

```systemverilog
if (load_pulse) begin
  shift_reg_next[ch] = shadow_reg[ch];
end
```

riadky `118–120`.

Toto je stále problém pre TMDS, pretože `load_pulse` nie je garantovane zarovnaný na hranicu 10-bitového slova. HDMI/TMDS potrebuje presne:

```text
1 pixel clock = 1 nové 10-bitové TMDS slovo
DDR režim: 5× clk_x_i × 2 bity = 10 bitov
```

Čiže load musí nastať presne každých 5 rýchlych taktov v DDR režime. CDC toggle ti síce prenesie udalosť, ale nie presnú fázu voči serializačnému počítadlu.

Odporúčanie: `generic_serializer` môže zostať ako všeobecný experimentálny serializér, ale pre HDMI by som spravil samostatný:

```text
tmds_phy_ddr_aligned
```

s logikou:

```systemverilog
logic [2:0] pair_cnt;

always_ff @(posedge clk_x_i) begin
  if (!rst_ni) begin
    pair_cnt <= 3'd0;
  end else if (pair_cnt == 3'd4) begin
    pair_cnt <= 3'd0;
  end else begin
    pair_cnt <= pair_cnt + 3'd1;
  end
end

wire load_word = (pair_cnt == 3'd0);
```

Až `load_word` má načítať nové 10-bitové slovo. Nie synchronizovaný toggle.

Toto je podľa mňa momentálne najväčší technický blocker pre stabilný obraz.

---

# 3. `tmds_video_encoder.sv`: dobré rozdelenie, ale TMDS algoritmus je podozrivý

Veľmi dobré je, že encoder už má `de_i`:

```systemverilog
input logic de_i
```

riadok `18`.

A running disparity resetuješ mimo active video:

```systemverilog
else if (!de_r) begin
  rd     <= 5'sd0;
  tmds_o <= '0;
end
```

riadky `85–89`.

To je správne.

Ale samotná DC-balance časť vyzerá zjednodušene a pravdepodobne nie je úplne podľa štandardného TMDS algoritmu.

Kritická časť:

```systemverilog
if (neutral)
  invert = q_m_r[8];
else if (rd == 5'sd0)
  invert = (char_disp > 5'sd0);
else
  invert = (rd > 5'sd0) ? (char_disp > 5'sd0) : (char_disp < 5'sd0);
```

riadky `101–106`.

Pri štandardnom TMDS algoritme je vetva `rd == 0` špeciálna a rozhoduje sa podľa `q_m[8]`, nie jednoducho podľa znamienka disparity. Pri neutrálnom znaku tiež nie je všeobecne správne robiť `invert = q_m_r[8]`.

Napríklad pri `q_m[8] = 1`, čo u teba znamená XOR path, štandardná forma typicky nevytvára `{1, 1, ~q_m}`, ale necháva neinvertovanú formu s prefixom zodpovedajúcim XOR vetve.

Odporúčanie: toto určite over testbenchom proti referenčnému TMDS enkóderu pre:

```text
všetkých 256 vstupných bajtov
viacero počiatočných hodnôt running disparity
DE prechody active/blanking/active
```

Momentálne by som tento encoder nepovažoval za overený.

---

# 4. `hdmi_tx_core.sv`: architektúra je správna, ale data-island vetva je stále placeholder

Pre DVI-only režim:

```systemverilog
parameter bit ENABLE_DATA_ISLAND = 0
```

riadok `21`, je core použiteľný na ďalšie ladenie.

Video/control cesta je už rozumne rozdelená:

```text
input register
→ period scheduler
→ TMDS video encoder
→ TMDS control encoder
→ period delay
→ channel mux
```

To je dobré.

Ale data-island časť ešte nie je HDMI-kompatibilná. Aktuálne robíš:

```systemverilog
pkt_byte[3:0] → TERC4 ch0
pkt_byte[7:4] → TERC4 ch1
4'h0          → TERC4 ch2
```

riadky `198–210`.

To nie je skutočný HDMI data island formát. Chýba blok:

```text
data_island_formatter
```

ktorý musí riešiť:

```text
packet header
subpacket layout
ECC/BCH
mapovanie na CH0/CH1/CH2 nibbles
TERC4 encoding
```

Preto odporúčam zatiaľ držať:

```systemverilog
ENABLE_DATA_ISLAND = 0
```

kým nebude stabilná čistá DVI/TMDS video cesta.

---

# 5. `packet_scheduler.sv`: consume handshake je už pridaný, ale paketová logika stále nie je HDMI packet formatter

Pozitívne: aktuálna verzia už má:

```systemverilog
input logic consume_i
```

riadok `43`.

A stav/idx posúva iba pri:

```systemverilog
else if (packet_ready_o && consume_i) begin
  state <= state_next;
  idx   <= (state_next != state) ? 6'd0 : idx_next;
end
```

riadky `170–173`.

To je správny smer. Predchádzajúca výhrada, že scheduler nemá handshake, už v tejto verzii neplatí.

Ale obsahovo je `packet_scheduler` stále skôr **byte-stream scheduler**, nie HDMI data-island formatter.

Napríklad ak `len_spd == 0`, stále prejde cez:

```systemverilog
ST_SPD_HEADER
```

riadky `109–118`, teda vyšle 3 bajty `header_spd`, ktoré sú v `hdmi_tx_core` pripojené ako nuly:

```systemverilog
.header_spd('{default:'0}),
.len_spd(6'd0),
```

riadky `184–186`.

To znamená, že aj „vypnutý“ SPD packet stále pošle 3 nulové header bajty. Podobne Audio header.

Ak má byť paket vypnutý, mal by sa preskočiť celý header aj payload.

Teda namiesto:

```text
SPD_HEADER → ak len_spd==0, preskoč payload
```

by malo byť:

```text
ak SPD disabled alebo len_spd==0:
  preskoč SPD_HEADER aj SPD_PAYLOAD
```

---

# 6. `hdmi_period_scheduler.sv`: funguje ako FSM, ale nevie, či sa data island zmestí do blankingu

Scheduler má pevnú sekvenciu:

```text
8 preamble
2 guard lead
32 payload
2 guard trail
```

riadky `66–68`.

To je spolu 44 pixel clockov. Spúšťa ju pri:

```systemverilog
else if (hblank_i && packet_pending_i)
```

riadok `84`.

Problém: nekontroluje, či zostáva aspoň 44 pixelov do najbližšieho active video. Ak `packet_pending_i` príde neskoro v blankingu, scheduler môže vojsť do active video.

Teraz síce v `hdmi_tx_core` máš default `ENABLE_DATA_ISLAND=0`, takže to nevadí pre DVI-only režim. Ale pre HDMI data islands bude treba pridať napríklad:

```systemverilog
input logic [15:0] blank_remaining_i;
```

a spúšťať data island iba keď:

```systemverilog
blank_remaining_i >= 16'd44
```

Alebo na začiatok povoľovať data islands iba vo vertical blankingu na bezpečnom mieste.

---

# 7. `hdmi_tx_core.sv`: `vblank` je odvodený nesprávne

V core máš:

```systemverilog
wire vblank = vsync_r;
wire hblank = ~de_r && ~vblank;
```

riadky `66–67`.

Toto nie je všeobecne správne.

`vsync` je iba synchronizačný pulz. `vblank` je celý interval mimo aktívnych riadkov. Navyše polarita `vsync` môže byť aktívne nízka, takže `vblank = vsync_r` je nebezpečné.

Pre DVI-only režim je to skoro jedno, pretože scheduler používa iba `de_i` na video/control. Ale pre data islands a InfoFrames to nestačí.

Odporúčanie: do `hdmi_tx_core` neskôr neposielať iba `de/hs/vs`, ale aj:

```systemverilog
input logic hblank_i;
input logic vblank_i;
input logic frame_start_i;
input logic line_start_i;
input logic [15:0] blank_remaining_i;
```

Tieto signály už vie produkovať `video_timing_generator`.

---

# 8. `video_stream_frame_aligner.sv`: SOF opravený, ale EOL/EOF vstupy sa nepoužívajú

Porty už máš:

```systemverilog
input logic last_active_x_i,
input logic last_active_pixel_i,
input logic s_axis_eol_i,
input logic s_axis_eof_i,
```

riadky `31–40`.

Ale v logike sa `last_active_x_i`, `last_active_pixel_i`, `s_axis_eol_i`, `s_axis_eof_i` prakticky nepoužívajú na kontrolu integrity rámca.

To znamená, že aligner zatiaľ kontroluje hlavne:

```text
SOF
underflow
neočakávaný SOF uprostred frame
```

ale nekontroluje:

```text
EOL na poslednom pixeli riadku
EOF na poslednom pixeli frame
chýbajúci EOL
chýbajúci EOF
predčasný EOF
```

Odporúčaná kontrola pri `pixel_take`:

```systemverilog
if (pixel_take) begin
  if (s_axis_eol_i != last_active_x_i) begin
    sync_error_o = 1'b1;
  end

  if (s_axis_eof_i != last_active_pixel_i) begin
    sync_error_o = 1'b1;
  end
end
```

Pozor ale na fázovanie: `last_active_x_i` a `last_active_pixel_i` sú teraz rovnaká fáza ako `de_o`, zatiaľ čo `pixel_req_i` je o takt skôr. Musíš ich buď tiež posunúť ako look-ahead, alebo kontrolu robiť v cykle, keď je pixel reálne zobrazovaný.

---

# 9. `video_stream_frame_aligner.sv`: `pixel_valid_o` môže byť významovo mätúci

Máš:

```systemverilog
wire pixel_take = pixel_req_i && (state_next == ST_STREAM_FRAME) && s_axis_valid_i;
```

riadok `134`.

A potom:

```systemverilog
pixel_valid_o <= pixel_take && de_i;
```

riadok `142`.

Lenže pri prvom pixeli frame nastane typicky:

```text
pixel_req_i = 1
frame_start_i = 1
de_i = 0
```

pretože `pixel_req_i` je o jeden takt vpredu. Vtedy sa prvý pixel načíta do `pixel_o`, ale `pixel_valid_o` bude 0. V ďalšom takte už `de_i=1` a VGA adapter použije predchádzajúci `pixel_o`.

To je funkčne OK, ak `pixel_valid_o` nepoužívaš ako „aktuálne zobrazený pixel je platný“. Ale názov môže zavádzať.

Odporúčanie:

* buď `pixel_valid_o` odstrániť, ak ho nepoužívaš,
* alebo ho definovať jasne ako `pixel_loaded_o`,
* alebo oneskoriť valid tak, aby sedel s `de_o` a reálnym výstupným pixelom.

---

# 10. `video_stream_fifo_sync.sv`: oprava wrapu je dobrá, ale syntax môže byť citlivá na nástroj

Teraz máš:

```systemverilog
function automatic logic [AW-1:0] ptr_next(input logic [AW-1:0] ptr);
  return (ptr == AW'(DEPTH - 1)) ? '0 : ptr + 1'b1;
endfunction
```

riadky `44–46`.

Myšlienka je správna: podporovať aj non-power-of-two `DEPTH`.

Ale zápis:

```systemverilog
AW'(DEPTH - 1)
```

nemusia všetky nástroje akceptovať rovnako. Bezpečnejšie je:

```systemverilog
localparam logic [AW-1:0] DEPTH_LAST = logic'(DEPTH - 1);
```

alebo explicitnejšie:

```systemverilog
localparam logic [AW-1:0] DEPTH_LAST = DEPTH - 1;

function automatic logic [AW-1:0] ptr_next(input logic [AW-1:0] ptr);
  return (ptr == DEPTH_LAST) ? '0 : ptr + 1'b1;
endfunction
```

Ešte by som pridal ochranu:

```systemverilog
initial begin
  assert (DEPTH >= 2)
    else $error("video_stream_fifo_sync: DEPTH must be >= 2");
end
```

pretože pri `DEPTH=1` bude `$clog2(DEPTH)` nulová šírka.

---

# 11. `vga_output_adapter.sv` je čistý a dobrý

Tento modul je presne taký, aký má byť:

```systemverilog
vga_r_o <= de_i ? pixel_i.red : 5'b0;
vga_g_o <= de_i ? pixel_i.grn : 6'b0;
vga_b_o <= de_i ? pixel_i.blu : 5'b0;
vga_hs_o <= hsync_i;
vga_vs_o <= vsync_i;
```

riadky `33–37`.

Toto je dobré zapuzdrenie: modul nerieši timing, FIFO ani stream sync. Iba vyvedie timed video na VGA piny.

Drobná vec: reset `vga_hs_o <= 1'b0`, `vga_vs_o <= 1'b0` nemusí byť neaktívny stav pre všetky polarity, ale prakticky to nie je kritické, ak reset trvá pred spustením výstupu.

---

# 12. `picture_gen_stream.sv` je už čistejší

Vidím, že enum už nemá pevné `3'd0`, `3'd1` atď. Teraz je:

```systemverilog
typedef enum logic [MODE_WIDTH-1:0] {
  MODE_CHECKER_SMALL,
  ...
  MODE_MOVING_BAR
} mode_e;
```

riadky `55–64`.

To je opravené.

Zostáva menšia šírková vec v `MODE_MOVING_BAR`:

```systemverilog
if (((x_q + X_WIDTH'(scroll_offset_q)) & 8'h3F) < 16)
```

riadok `186`.

Pre bežné šírky to bude fungovať, ale čistejšie je:

```systemverilog
logic [15:0] x_scroll;
x_scroll = 16'(x_q) + 16'(scroll_offset_q);

if (x_scroll[5:0] < 6'd16)
  data_next = RED;
else
  data_next = BLACK;
```

Tým sa vyhneš miešaniu šírky `X_WIDTH` a masky `8'h3F`.

---

# 13. `hdmi_channel_mux.sv`: koncept dobrý, ale HDMI guard/preamble sú stále skôr placeholder

Mux ako taký je dobrý. Vyberá medzi:

```text
video
control
data island
guard band
```

podľa `hdmi_period_t`.

Ale tieto hodnoty:

```systemverilog
GB_VIDEO  = 10'b1011001100;
GB_DATA_0 = 10'b0100110011;
GB_DATA_N = 10'b0100110011;
```

riadky `37–39`, by som zatiaľ bral ako placeholder, kým nebudeš robiť plné HDMI data islands.

`HDMI_PERIOD_VIDEO_GB` sa v aktuálnom `hdmi_period_scheduler` ani negeneruje, takže pre DVI-only režim to nevadí.

---

# 14. Veci, ktoré sú teraz naozaj dobré

Aktuálna verzia už vyriešila viacero vecí, ktoré som predtým kritizoval:

```text
+ vga_hdmi_tx už používa hdmi_tx_core
+ hdmi_pkg má hdmi_period_t aj hdmi_info_cfg_t
+ generic_serializer má logic load_toggle
+ tmds_video_encoder má de_i a resetuje disparity mimo DE
+ packet_scheduler má consume_i
+ infoframe_builder má opravený checksum/payload_len model
+ video_timing_generator má skutočný look-ahead pixel_req_o
+ video_stream_frame_aligner už nezahadzuje SOF pixel
+ video_stream_fifo_sync má non-power-of-two wrap logiku
+ vga_output_adapter je čistý adapter
```

Toto je dobrý refaktor.

---

# 15. Veci, ktoré by som opravil ako ďalšie

Prioritne:

```text
1. Nahradiť generic_serializer špeciálnym word-aligned TMDS PHY.
2. Overiť tmds_video_encoder proti referenčnému TMDS algoritmu.
3. Držať ENABLE_DATA_ISLAND=0, kým nebude stabilný DVI obraz.
4. Do hdmi_tx_core neskôr pridať reálne hblank/vblank/frame_start/blank_remaining vstupy.
5. V packet_scheduler preskakovať celé vypnuté pakety, nie iba payload.
6. Doplniť data_island_formatter pred TERC4.
7. V aligneri doplniť EOL/EOF kontrolu alebo odstrániť nepoužité porty.
8. Ujasniť význam pixel_valid_o.
```

---

# 16. Moje aktuálne hodnotenie

Tento refaktor je už **podstatne lepší než predchádzajúci stav**. Kód má správne delenie:

```text
video timing
stream FIFO
frame aligner
VGA adapter
HDMI core
TMDS video/control encodery
TERC4
channel mux
PHY/serializer
```

Najväčšia vec, ktorá stále drží projekt späť, je PHY/serializácia. Aj keby bol HDMI core správny, nezarovnaný serializer môže rozbiť celý TMDS stream.

Preto by som teraz neriešil audio ani InfoFrames. Najbližší cieľ by mal byť:

```text
RGB565 timed video
    ↓
RGB888
    ↓
hdmi_tx_core, ENABLE_DATA_ISLAND=0
    ↓
word-aligned TMDS PHY
    ↓
stabilný obraz na monitore
```

Až potom by som pokračoval na data islands, AVI InfoFrame a audio.
