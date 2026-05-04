Refaktor je **architektonicky lepším smerom**, ale momentálne je v stave „polovičný refaktor“: nové čisté bloky vznikli, no výstupná cesta stále používa starý `hdmi_tx_top` a starý `tmds_encoder_pipelined`. Preto sa veľká časť dobrej práce zatiaľ reálne nepoužíva.

Najdôležitejšie zhrnutie:

```text
Dobré:
+ vznikol hdmi_tx_core oddelený od PHY
+ video/control/TERC4 enkódery sú oddelené
+ channel_mux je samostatný
+ period_scheduler je samostatný FSM
+ smeruješ k správnej architektúre

Kritické:
- nové typy hdmi_period_t / HDMI_PERIOD_* chýbajú v hdmi_pkg
- hdmi_tx_core sa nikde nepoužíva v reálnej top ceste
- vga_hdmi_tx stále inštancuje starý hdmi_tx_top
- generic_serializer má stále vážny problém s word alignment
- tmds_video_encoder si aktualizuje running disparity aj počas blankingu
- packet_scheduler nemá handshake so schedulerom
- data-island/TERC4 cesta ešte nie je štandardovo správna
- InfoFrame payload length je stále off-by-one
```

---

# 1. Najväčší problém: máš dve HDMI architektúry naraz

Teraz máš:

```text
nová architektúra:
hdmi_tx_core
├── hdmi_period_scheduler
├── tmds_video_encoder
├── tmds_control_encoder
├── terc4_encoder
└── hdmi_channel_mux

stará architektúra:
hdmi_tx_top
├── FSM VIDEO/AUDIO/DATA/CONTROL
├── tmds_encoder_pipelined × 3
└── generic_serializer
```

Ale `vga_hdmi_tx.sv` stále používa toto:

```systemverilog
hdmi_tx_top #(
  .DDRIO(1)
) u_hdmi_tx (
  ...
);
```

Čiže nové bloky ako `hdmi_tx_core`, `hdmi_period_scheduler`, `tmds_video_encoder`, `tmds_control_encoder`, `terc4_encoder` sa v reálnej VGA→HDMI ceste nepoužijú.

## Čo prerobiť

`vga_hdmi_tx` by nemal inštancovať starý `hdmi_tx_top`, ale novú zostavu:

```text
vga_hdmi_tx
├── rgb565_to_rgb888
├── hdmi_tx_core
└── tmds_phy / serializer
```

Teda:

```systemverilog
hdmi_tx_core #(
  .ENABLE_DATA_ISLAND(0)
) u_core (
  .pix_clk_i (clk_i),
  .rst_ni    (rst_ni),

  .red_i     (video.red),
  .grn_i     (video.grn),
  .blu_i     (video.blu),
  .de_i      (vga_de_i),
  .hsync_i   (vga_hs_i),
  .vsync_i   (vga_vs_i),

  .info_cfg_i      ('0),
  .color_fmt_i     (COLOR_FORMAT_RGB),
  .aspect_ratio_i  (ASPECT_RATIO_4_3),
  .quant_range_i   (QUANT_RANGE_FULL),
  .vic_code_i      (8'd0),

  .ch0_o(tmds_ch0),
  .ch1_o(tmds_ch1),
  .ch2_o(tmds_ch2)
);
```

Potom až:

```systemverilog
tmds_phy_generic_or_vendor u_phy (
  .pix_clk_i(clk_i),
  .ser_clk_i(clk_x_i),
  .ch0_i(tmds_ch0),
  .ch1_i(tmds_ch1),
  .ch2_i(tmds_ch2),
  ...
);
```

Starý `hdmi_tx_top` by som buď odstránil, alebo premenoval na:

```text
hdmi_tx_top_legacy.sv
```

aby bolo jasné, že už nemá byť hlavná cesta.

---

# 2. `hdmi_pkg.sv` je nekompatibilný s novými modulmi

Nové moduly používajú:

```systemverilog
hdmi_period_t
HDMI_PERIOD_CONTROL
HDMI_PERIOD_VIDEO
HDMI_PERIOD_VIDEO_GB
HDMI_PERIOD_DATA_PREAMBLE
HDMI_PERIOD_DATA_GB_LEAD
HDMI_PERIOD_DATA_PAYLOAD
HDMI_PERIOD_DATA_GB_TRAIL
```

Ale v `hdmi_pkg.sv` máš iba starý typ:

```systemverilog
typedef enum logic [1:0] {
    VIDEO_PERIOD,
    CONTROL_PERIOD,
    AUDIO_PERIOD,
    DATA_PERIOD
} tmds_period_e;
```

To znamená, že nové súbory `hdmi_tx_core.sv`, `hdmi_period_scheduler.sv` a `hdmi_channel_mux.sv` by nemali prejsť kompiláciou bez chyby.

## Čo prerobiť

Do `hdmi_pkg.sv` doplniť nový enum:

```systemverilog
typedef enum logic [2:0] {
  HDMI_PERIOD_CONTROL,
  HDMI_PERIOD_VIDEO,
  HDMI_PERIOD_VIDEO_GB,
  HDMI_PERIOD_DATA_PREAMBLE,
  HDMI_PERIOD_DATA_GB_LEAD,
  HDMI_PERIOD_DATA_PAYLOAD,
  HDMI_PERIOD_DATA_GB_TRAIL
} hdmi_period_t;
```

Starý enum:

```systemverilog
tmds_period_e
```

by som ponechal iba pre legacy `tmds_encoder_pipelined`, alebo ho úplne odstránil po vyradení starej architektúry.

---

# 3. `hdmi_info_cfg_t` chýba

V `hdmi_tx_core.sv` máš vstup:

```systemverilog
input hdmi_info_cfg_t info_cfg_i,
```

ale v `hdmi_pkg.sv` takýto typ neexistuje.

Buď ho doplň:

```systemverilog
typedef struct packed {
  logic send_avi;
  logic send_spd;
  logic send_audio;
  logic send_vendor;
} hdmi_info_cfg_t;
```

alebo zatiaľ tento port odstráň, keďže sa v `hdmi_tx_core` aktuálne aj tak nepoužíva.

Momentálne sú zároveň nepoužité aj parametre:

```systemverilog
ENABLE_AVI
ENABLE_SPD
ENABLE_AUDIO_IF
```

To nie je syntaktická chyba, ale je to znak, že refaktor ešte nie je dokončený.

---

# 4. `generic_serializer.sv` má stále kritický problém

V serializéri je stále:

```systemverilog
wire load_toggle;

always_ff @(posedge clk_i) begin
  ...
  load_toggle <= 1'b0;
```

To je chyba. Signál priraďovaný v `always_ff` musí byť `logic`, nie `wire`.

Oprava:

```systemverilog
logic load_toggle;
```

Ale to je iba syntaktická oprava. Väčší problém zostáva architektonický.

## Väčší problém: serializér stále nie je word-aligned

Používaš `load_toggle` cez CDC:

```text
clk_i → load_toggle → clk_x_i → load_pulse
```

Toto negarantuje, že nové 10-bitové TMDS slovo sa načíta presne na hranici 10-bitového symbolu.

Pre TMDS potrebuješ:

```text
každý pixel clock:
  nové 10-bit slovo

v rýchlej doméne:
  presne 5 DDR taktov = 10 bitov
  potom load ďalšie slovo
```

Teraz môže `load_pulse` prísť v ľubovoľnom bode posúvania. To rozbije serializáciu.

## Čo prerobiť

Namiesto všeobecného CDC toggle serializéra sprav samostatný TMDS PHY/gearbox:

```text
pix_clk doména:
  ch0/ch1/ch2 10-bit registre

ser_clk doména:
  counter 0..4 pri DDR
  counter == 0 → load word
  každý ser_clk → pošli 2 bity
```

Koncept:

```systemverilog
logic [2:0] pair_cnt;

always_ff @(posedge ser_clk_i) begin
  if (!rst_ni) begin
    pair_cnt <= 3'd0;
  end else begin
    if (pair_cnt == 3'd4)
      pair_cnt <= 3'd0;
    else
      pair_cnt <= pair_cnt + 3'd1;
  end
end
```

Load nového slova má byť viazaný na:

```systemverilog
pair_cnt == 0
```

nie na oneskorený CDC impulz.

---

# 5. `tmds_video_encoder.sv` má vážny problém s running disparity

Nový `tmds_video_encoder` je čistejší než starý encoder. Ale má zásadný problém: **beží neustále**, aj počas blankingu/control/data-island periód.

V `hdmi_tx_core` sú video enkódery stále napájané registrovaným RGB:

```systemverilog
.data_i(red_r)
.data_i(grn_r)
.data_i(blu_r)
```

a encoder si v každom takte aktualizuje:

```systemverilog
rd <= rd_next;
```

Aj keď výstup video encoderu práve nie je použitý.

To je zlé, pretože TMDS running disparity sa má pre video cestu resetovať alebo minimálne prestať aktualizovať počas control period. V tvojej architektúre sa počas blankingu síce vyberie `ctrl_ch*`, ale vnútorný `rd` vo video encoderi ďalej „uteká“ podľa RGB hodnôt počas blankingu.

Výsledok:

```text
po blankingu začne active video s nesprávnou running disparity
```

## Čo prerobiť

Pridaj do `tmds_video_encoder` vstup:

```systemverilog
input logic video_enable_i
```

alebo:

```systemverilog
input logic reset_disparity_i
```

Odporúčam toto:

```systemverilog
module tmds_video_encoder (
  input  logic       clk_i,
  input  logic       rst_ni,
  input  logic       de_i,
  input  tmds_data_t data_i,
  output tmds_word_t tmds_o
);
```

A vnútri:

```systemverilog
if (!rst_ni) begin
  rd <= '0;
end else if (!de_i) begin
  rd <= '0;
end else begin
  rd <= rd_next;
end
```

Ak chceš zachovať čistý video-only encoder, potom mu aspoň daj:

```systemverilog
input logic rd_reset_i;
input logic update_i;
```

a z `hdmi_tx_core` ho riaď podľa `period == HDMI_PERIOD_VIDEO`.

---

# 6. Zarovnanie control/video ciest je podozrivé

V `hdmi_tx_core.sv` komentár tvrdí:

```text
Total latency = 3 pixel clocks
```

ale praktická latencia medzi:

```text
RGB/de/hs/vs vstupom
```

a výberom v muxe nie je jednoznačne správna.

Konkrétne:

```systemverilog
red_r <= red_i;
de_r  <= de_i;
```

potom scheduler beží z `de_r`, video encoder beží z `red_r`, period sa ešte oneskoruje cez:

```systemverilog
period_d1 <= period;
period_d2 <= period_d1;
```

a control cesta navyše oneskoruje sync:

```systemverilog
hsync_d <= hsync_r;
vsync_d <= vsync_r;
```

potom ide do `tmds_control_encoder`, ktorý má ďalšie 2 takty latencie.

To vyzerá tak, že control symboly môžu byť oneskorené inak než video symboly.

## Čo prerobiť

Sprav si explicitné latency pipeline pre všetky súvisiace signály:

```systemverilog
localparam int VIDEO_ENCODER_LATENCY = 2;
localparam int MUX_LATENCY           = 1;
```

A potom oneskoruj `de/hs/vs/period` cez jeden všeobecný delay modul:

```systemverilog
hdmi_delay #(
  .WIDTH(3),
  .LATENCY(VIDEO_ENCODER_LATENCY)
) u_ctrl_delay (
  .clk_i(pix_clk_i),
  .rst_ni(rst_ni),
  .din_i({de_r, hsync_r, vsync_r}),
  .dout_o({de_enc_aligned, hsync_enc_aligned, vsync_enc_aligned})
);
```

Nerobil by som špeciálny `hsync_d` ručne, kým nie je presne spočítaná latencia každej vetvy.

---

# 7. `packet_scheduler` nemá handshake so `hdmi_period_scheduler`

Toto je veľmi dôležité.

V `hdmi_tx_core` máš:

```systemverilog
assign packet_pending = pkt_ready;
```

ale signály zo scheduleru:

```systemverilog
packet_start
packet_pop
```

sa nikde nepoužívajú.

`packet_scheduler` teda posúva svoje bajty podľa vlastného FSM po `eof_i`, bez ohľadu na to, či `hdmi_period_scheduler` práve posiela:

```text
preamble
guard band
payload
control
video
```

To znamená, že packet byte môže byť už dávno posunutý skôr, než sa vôbec začne `HDMI_PERIOD_DATA_PAYLOAD`.

## Čo prerobiť

`packet_scheduler` musí mať vstup:

```systemverilog
input logic packet_consume_i;
```

a iba pri ňom posunúť index:

```systemverilog
if (packet_consume_i) begin
  idx <= idx_next;
end
```

Potom v `hdmi_tx_core`:

```systemverilog
.packet_consume_i(packet_pop_aligned)
```

Ale pozor: ak má `terc4_encoder` jeden takt latencie, musíš zarovnať `packet_pop` s dátovou cestou.

Lepšia architektúra:

```text
packet_scheduler
    drží aktuálny packet symbol
    ↓ valid
period_scheduler
    počas DATA_PAYLOAD dá consume/pop
    ↓
data_island_formatter
    zoberie bajt/nibble a pripraví TERC4 vstupy
```

---

# 8. Data-island cesta ešte nie je štandardovo správna

Aktuálne máš:

```systemverilog
pkt_byte[3:0] → ch0 TERC4
pkt_byte[7:4] → ch1 TERC4
4'h0          → ch2 TERC4
```

To je dobré ako dočasný experiment, ale nie ako HDMI data island.

HDMI data island nie je obyčajné:

```text
byte → dva nibbles → dva TMDS kanály
```

Potrebuješ samostatný formatter:

```text
InfoFrame/audio packet
    ↓
header/body layout
    ↓
ECC/BCH
    ↓
subpacket mapping
    ↓
TERC4 nibble per channel
```

Takže modul, ktorý teraz chýba, je:

```text
data_island_formatter.sv
```

Ten by mal produkovať:

```systemverilog
typedef struct packed {
  logic [3:0] ch0_nibble;
  logic [3:0] ch1_nibble;
  logic [3:0] ch2_nibble;
  logic       valid;
} hdmi_data_island_symbol_t;
```

Až potom:

```text
ch0_nibble → TERC4
ch1_nibble → TERC4
ch2_nibble → TERC4
```

---

# 9. `hdmi_period_scheduler` môže spustiť data island príliš neskoro

Scheduler má fixné dĺžky:

```systemverilog
PREAMBLE_LEN = 8
GUARD_LEN    = 2
PAYLOAD_LEN  = 32
```

Celý data island teda potrebuje:

```text
8 + 2 + 32 + 2 = 44 pixel clockov
```

Ale scheduler kontroluje iba:

```systemverilog
if (hblank_i && packet_pending_i)
```

Neoveruje, či v aktuálnom blankingu ešte zostáva aspoň 44 taktov.

Ak sa packet objaví napríklad 10 taktov pred active video, scheduler začne data island a bude pokračovať cez začiatok active video. To rozbije obraz.

## Čo prerobiť

Period scheduler potrebuje vedieť:

```systemverilog
input logic [15:0] blank_remaining_i;
```

alebo aspoň:

```systemverilog
input logic data_island_window_i;
```

Potom:

```systemverilog
if (hblank_i && packet_pending_i && blank_remaining_i >= DATA_ISLAND_TOTAL)
  start_data_island;
```

Minimálne na začiatok povoľ data islands iba v bezpečnej časti vblanku.

---

# 10. `hblank` a `vblank` sú teraz rovnaké

V `hdmi_tx_core.sv` máš:

```systemverilog
wire hblank = ~de_r;
wire vblank = ~de_r;
```

To je zjednodušenie, ale pre scheduler to znamená:

```text
každý blanking je zároveň horizontal aj vertical blank
```

To nie je dostatočné pre HDMI scheduler. Hlavne ak budeš plánovať InfoFrames raz za frame, audio počas blankingu a pod.

## Čo prerobiť

Do `hdmi_tx_core` by som pridal explicitné vstupy z timing generátora:

```systemverilog
input logic hblank_i;
input logic vblank_i;
input logic frame_start_i;
input logic line_start_i;
input logic [15:0] x_i;
input logic [15:0] y_i;
input logic [15:0] blank_remaining_i;
```

Alebo jednoduchší variant pre prvú verziu:

```systemverilog
input logic frame_start_i;
input logic line_start_i;
```

A `hblank/vblank` generovať ešte vo video timing vrstve.

---

# 11. InfoFrame length je stále off-by-one

V `infoframe_builder.sv` pre AVI:

```systemverilog
header_o[2]   = AviLENGTH;  // 13
payload_len_o = AviLENGTH;
payload_o[0]  = checksum
payload_o[1]  = PB1
...
payload_o[13] = PB13
```

Ak `payload_o[0]` je checksum a `payload_o[1]..payload_o[13]` sú AVI payload bajty, potom celkový počet bajtov na odoslanie z poľa `payload_o` je:

```text
checksum + 13 payload bajtov = 14
```

Ale ty nastavuješ:

```systemverilog
payload_len_o = 13
```

Výsledok:

```text
odošle sa payload_o[0] až payload_o[12]
payload_o[13] sa neodošle
checksum tiež nezahŕňa posledný payload bajt
```

Rovnaký problém je pri SPD a Audio.

## Oprava

Zachovaj HDMI header length ako štandardnú hodnotu:

```systemverilog
header_o[2] = AviLENGTH; // 13
```

ale interný počet bajtov v poli nastav:

```systemverilog
payload_len_o = AviLENGTH + 1;
```

Teda:

```systemverilog
INFO_AVI: begin
  header_o[0]   = INFO_AVI;
  header_o[1]   = AviVERSION;
  header_o[2]   = AviLENGTH;
  payload_len_o = AviLENGTH + 1;
end
```

Podobne:

```systemverilog
payload_len_o = SpdLENGTH + 1;
payload_len_o = AudioLENGTH + 1;
```

Checksum funkcia potom správne sčíta:

```systemverilog
for (i = 1; i < payload_len; i++)
```

čiže PB1 až PBN.

---

# 12. `hdmi_channel_mux.sv` je dobrý nápad, ale preambuly/guard bandy sú zatiaľ zjednodušené

Mux ako samostatný blok je správne.

Ale aktuálne:

```systemverilog
HDMI_PERIOD_DATA_PREAMBLE: begin
  ch2_next = ctrl_ch2_i;
  ch1_next = ctrl_ch1_i;
  ch0_next = ctrl_ch0_i;
end
```

To v skutočnosti nie je plná HDMI preambula. HDMI preambula používa control symboly s konkrétnymi control hodnotami, ktoré oznamujú nasledujúcu periódu. Nestačí len „aktuálne control symboly“.

Tiež guard-band symboly treba overiť podľa kanálu a typu guard bandu. Teraz máš:

```systemverilog
GB_DATA_0 = 10'b0100110011
GB_DATA_N = 10'b0100110011
```

Rovnaký symbol pre všetko je pravdepodobne iba placeholder.

## Čo prerobiť

Rozdeľ control encoder tak, aby vedel kódovať širšie control hodnoty pre HDMI preambulu:

```text
control period:
  ch0: HS/VS
  ch1/ch2: CTL pre preambulu video/data island
```

Prakticky budeš potrebovať:

```systemverilog
logic [1:0] ctl_ch0;
logic [1:0] ctl_ch1;
logic [1:0] ctl_ch2;
```

nie iba:

```systemverilog
ch0 = {vsync, hsync}
ch1 = 2'b00
ch2 = 2'b00
```

---

# 13. `hdmi_tx_top.sv` by som už nepovažoval za refaktorovaný

Tento súbor je stále pôvodný štýl:

```text
FSM VIDEO/AUDIO/DATA/CONTROL
    ↓
tmds_encoder_pipelined
    ↓
generic_serializer
```

A stále má starý problém:

```systemverilog
AUDIO_PERIOD:
  encoder_data_blu = audio_i;

DATA_PERIOD:
  encoder_data_blu = packet_i;
```

Toto nie je správny HDMI audio/data island prenos.

Ak chceš zachovať tento súbor, navrhol by som ho premeniť na wrapper:

```text
hdmi_tx_top
├── hdmi_tx_core
└── tmds_phy
```

Teda `hdmi_tx_top` by už nemal obsahovať starý FSM ani `tmds_encoder_pipelined`.

---

# 14. Čo by som odstránil alebo presunul

## Odstrániť / odložiť ako legacy

```text
tmds_encoder_pipelined.sv
hdmi_tx_top.sv v aktuálnej podobe
packet_streamer.sv
```

Alebo ich premenovať:

```text
tmds_encoder_pipelined_legacy.sv
hdmi_tx_top_legacy.sv
packet_streamer_legacy.sv
```

## Nechať a ďalej rozvíjať

```text
hdmi_tx_core.sv
hdmi_period_scheduler.sv
tmds_video_encoder.sv
tmds_control_encoder.sv
terc4_encoder.sv
hdmi_channel_mux.sv
infoframe_builder.sv
packet_scheduler.sv
```

## Presunúť do PHY vrstvy

```text
generic_serializer.sv
```

ale po prerobení na word-aligned TMDS serializer.

---

# 15. Odporúčaný ďalší krok

Najprv by som neriešil plné HDMI data islands. Najprv sprav čistý DVI-compatible výstup cez novú architektúru.

## Krok 1: DVI-only cesta

```text
vga_hdmi_tx
    ↓
rgb565_to_rgb888
    ↓
hdmi_tx_core ENABLE_DATA_ISLAND=0
    ↓
tmds_phy_word_aligned
```

Cieľ:

```text
obraz funguje stabilne
DE/HS/VS sú zarovnané
TMDS video encoder má správne running disparity
serializer je word-aligned
```

## Krok 2: až potom data islands

Doplniť:

```text
InfoFrame builder
packet scheduler s consume handshake
data_island_formatter
TERC4
period scheduler s blank_remaining_i
```

---

# 16. Konkrétny minimálny patch pre package

Do `hdmi_pkg.sv` by som doplnil:

```systemverilog
typedef enum logic [2:0] {
  HDMI_PERIOD_CONTROL,
  HDMI_PERIOD_VIDEO,
  HDMI_PERIOD_VIDEO_GB,
  HDMI_PERIOD_DATA_PREAMBLE,
  HDMI_PERIOD_DATA_GB_LEAD,
  HDMI_PERIOD_DATA_PAYLOAD,
  HDMI_PERIOD_DATA_GB_TRAIL
} hdmi_period_t;

typedef struct packed {
  logic send_avi;
  logic send_spd;
  logic send_audio;
  logic send_vendor;
} hdmi_info_cfg_t;
```

A `infoframe_builder` opravil:

```systemverilog
payload_len_o = AviLENGTH + 1;
```

---

# 17. Konkrétna úprava `tmds_video_encoder`

Pridal by som:

```systemverilog
input logic active_i
```

A upravil running disparity:

```systemverilog
always_ff @(posedge clk_i) begin
  if (!rst_ni) begin
    tmds_o <= '0;
    rd     <= 5'sd0;
  end else if (!active_i) begin
    rd     <= 5'sd0;
    tmds_o <= '0;
  end else begin
    tmds_o <= word;
    rd     <= rd_next;
  end
end
```

Potom v `hdmi_tx_core` treba `active_i` oneskoriť tak, aby sedel s dátami vstupujúcimi do encoderu.

---

# 18. Konkrétna úprava packet scheduleru

Pridať vstup:

```systemverilog
input logic consume_i
```

A v FSM neposúvať `idx`, pokiaľ `consume_i == 0`.

Princíp:

```systemverilog
packet_valid_o = state != ST_IDLE;

if (packet_valid_o && consume_i) begin
  idx <= idx_next;
  state <= state_next;
end
```

Potom:

```systemverilog
.consume_i(packet_pop)
```

z `hdmi_period_scheduler`.

---

# 19. Celkové hodnotenie

Refaktor je dobrý smerom, ale ešte nie je funkčne uzavretý.

## Čo sa výrazne zlepšilo

```text
+ máš oddelené protokolové bloky
+ hdmi_tx_core je správna myšlienka
+ channel_mux je dobrá hranica medzi typmi periód
+ TERC4 encoder je samostatný
+ period scheduler je samostatný FSM
+ smeruješ k oddeleniu core od PHY
```

## Čo stále blokuje použiteľnosť

```text
- nové typy chýbajú v package
- nová architektúra nie je zapojená do top-levelu
- serializer stále nie je bezpečný pre TMDS
- video encoder zle spravuje running disparity počas blankingu
- packet scheduler nie je riadený period schedulerom
- data-island formát zatiaľ nie je HDMI-kompatibilný
- InfoFrame length je stále zle
```

---

# 20. Najdôležitejšie odporúčanie

Teraz by som urobil toto poradie:

```text
1. Opraviť hdmi_pkg: hdmi_period_t, hdmi_info_cfg_t.
2. Vyradiť starý hdmi_tx_top z hlavnej cesty.
3. Pripojiť vga_hdmi_tx na hdmi_tx_core.
4. Dočasne použiť ENABLE_DATA_ISLAND=0.
5. Opraviť tmds_video_encoder running disparity cez active/reset vstup.
6. Nahradiť generic_serializer word-aligned TMDS PHY modulom.
7. Až potom riešiť packet_scheduler/data-island/InfoFrame.
```

Jedna veta: **refaktor správne rozdelil HDMI core na logické bloky, ale top-level a serializer ešte zostali v starej filozofii; najprv dokonči DVI-compatible novú cestu a až potom pridávaj HDMI data islands.**
