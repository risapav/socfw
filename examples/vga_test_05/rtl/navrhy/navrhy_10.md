Teraz už analýza sedí na aktuálne nahraté súbory. Táto sada je výrazne ďalej než tie predošlé: používa `tmds_phy_ddr_aligned`, má `ST_VIDEO_PREAMBLE`, má `blank_remaining_i`, má zapojený `data_island_formatter`, dynamický CH0 data guard band a opravenú polaritu TMDS video cez `tmds_o <= ~word`.

Nižšie je aktuálne hodnotenie a ďalší postup k plnému HDMI.

---

## Aktuálna architektúra

Podľa súborov je tok teraz:

```text
video_timing_generator
  ├─ de / hsync / vsync
  ├─ hblank / vblank
  ├─ blank_remaining
  └─ frame_start

vga_hdmi_tx
  ├─ RGB565 → RGB888
  ├─ hdmi_tx_core
  └─ tmds_phy_ddr_aligned

hdmi_tx_core
  ├─ hdmi_period_scheduler
  ├─ tmds_video_encoder ×3
  ├─ tmds_control_encoder ×3
  ├─ infoframe_builder AVI
  ├─ data_island_formatter
  ├─ terc4_encoder ×3
  └─ hdmi_channel_mux
```

Toto je už správna kostra pre HDMI TX.

---

## Čo je už dobré

### 1. `vga_hdmi_tx.sv`

Aktuálne používa:

```systemverilog
tmds_phy_ddr_aligned u_phy (
```

a nie `generic_serializer`. To je správne.

Tiež už prijíma:

```systemverilog
hblank_i
vblank_i
frame_start_i
blank_remaining_i
```

a posiela ich do `hdmi_tx_core`.

Chýba mu ešte `line_start_i`, čo sa bude hodiť pri presnejšom plánovaní packetov vo vertical blankingu, ale pre aktuálny AVI-only pokus to nie je nutné.

---

### 2. `tmds_video_encoder.sv`

Oprava farieb je už priamo v encoderi:

```systemverilog
tmds_o <= ~word;
```

To je správne miesto opravy. Mux už nemusí invertovať video.

---

### 3. `hdmi_period_scheduler.sv`

Scheduler už má 8-stavový FSM:

```systemverilog
ST_CONTROL,
ST_VIDEO_PREAMBLE,
ST_VIDEO_GB,
ST_VIDEO,
ST_DATA_PREAMBLE,
ST_DATA_GB_LEAD,
ST_DATA_PAYLOAD,
ST_DATA_GB_TRAIL
```

To je správny smer.

Tiež už má:

```systemverilog
blank_remaining_i
```

a data island štartuje len keď je dostatok miesta:

```systemverilog
blank_remaining_i >= ISLAND_TOTAL + VIDEO_TRIG
```

To je zásadné zlepšenie.

---

### 4. `hdmi_channel_mux.sv`

Mux už má:

```systemverilog
HDMI_PERIOD_VIDEO_PREAMBLE
HDMI_PERIOD_VIDEO_GB
HDMI_PERIOD_DATA_PREAMBLE
HDMI_PERIOD_DATA_GB_LEAD
HDMI_PERIOD_DATA_PAYLOAD
HDMI_PERIOD_DATA_GB_TRAIL
```

a dynamický CH0 data guard band:

```systemverilog
gb_data_ch0 = TERC4({1, vsync, hsync, 1})
```

implementovaný cez `case ({vsync_i, hsync_i})`.

Toto je presne oprava, ktorú sme chceli.

---

### 5. `data_island_formatter.sv`

Formatter je zapojený v `hdmi_tx_core` a robí:

```text
HB0..HB2 + BCH
PB0..PB27 + subpacket BCH
→ 32 symbol periods
→ ch0/ch1/ch2 TERC4 nibbles
```

To je správna architektúra data island vrstvy.

---

## Hlavný problém, ktorý stále vidím

### `packet_pending` sa stále spúšťa na hrane `vsync`

V `hdmi_tx_core.sv` je:

```systemverilog
logic vsync_prev;
always_ff @(posedge pix_clk_i) vsync_prev <= vsync_r;

logic pending;
always_ff @(posedge pix_clk_i) begin
  if (!rst_ni)       pending <= 1'b0;
  else if (vsync_r && !vsync_prev) pending <= 1'b1;
  else if (packet_start)           pending <= 1'b0;
end
assign packet_pending = pending;
```

Toto je aktuálne najpodozrivejšia časť vzhľadom na problém, ktorý si popisoval:

```text
ENABLE_DATA_ISLAND=1 → obraz je posunutý nižšie o 2 riadky
```

Prečo?

Pretože packet začneš plánovať priamo na hrane VSYNC. V HDMI data islande channel 0 prenáša HS/VS informáciu aj počas payloadu/guard bandu. Ak packet vložíš okolo citlivej VSYNC oblasti alebo s nesprávne fázovaným `vsync_r`, sink môže posunúť interpretáciu frame začiatku.

### Odporúčaná oprava

Nepúšťaj AVI packet na `vsync rising edge`.

Použi bezpečné miesto vo vertical blankingu. Na to by som doplnil do `vga_hdmi_tx` a `hdmi_tx_core` aj:

```systemverilog
input logic line_start_i
```

Potom v `hdmi_tx_core` spraviť:

```systemverilog
logic [7:0] vblank_line_cnt;
logic       pending;

always_ff @(posedge pix_clk_i) begin
  if (!rst_ni) begin
    vblank_line_cnt <= 8'd0;
    pending         <= 1'b0;
  end else begin
    if (frame_start_i) begin
      vblank_line_cnt <= 8'd0;
      pending         <= 1'b0;
    end else if (line_start_i && vblank_r) begin
      vblank_line_cnt <= vblank_line_cnt + 1'b1;

      if (vblank_line_cnt == 8'd4)
        pending <= 1'b1;
    end

    if (packet_start)
      pending <= 1'b0;
  end
end
```

Teda AVI pošli až napríklad po 4. riadku vertical blankingu, nie priamo pri VSYNC hrane.

Ak sa tým stratí 2-riadkový posun, našiel si príčinu.

---

## Druhý problém: fázovanie HS/VS do `data_island_formatter`

V `hdmi_tx_core.sv` je formatter pripojený takto:

```systemverilog
.hsync_i  (hsync_r),
.vsync_i  (vsync_r),
```

Ale mux používa pre guard band:

```systemverilog
.vsync_i (vsync_enc),
.hsync_i (hsync_enc),
```

kde `vsync_enc/hsync_enc` sú oneskorené o 2 takty.

To znamená, že:

```text
data island payload ch0 používa hsync_r/vsync_r
data island guard band ch0 používa hsync_enc/vsync_enc
```

Môže to byť fázovo nejednotné.

Pre čistotu by som formatteru poslal rovnakú pipeline fázu ako muxu/TERC4 výstupu vyžaduje. Keďže TERC4 má 2-taktovú latenciu, nie je úplne triviálne, čo má byť správna fáza, ale aktuálne by som to explicitne overil simuláciou.

Najjednoduchší praktický test:

```text
porovnať ch0_o z formattera počas DATA_PAYLOAD
s ch0 guard bandom počas DATA_GB_LEAD/TRAIL,
či HS/VS bity zodpovedajú tej istej raster pozícii.
```

Ak chceš byť konzistentný, môžeš skúsiť formatter napojiť na oneskorené sync:

```systemverilog
.hsync_i(hsync_enc),
.vsync_i(vsync_enc),
```

ale pozor: tým môžeš pridať posun voči payloadu. Odporúčam to najprv simulovať.

---

## Tretí problém: `frame_start_i` je v core privedený, ale zatiaľ sa nepoužíva

V `hdmi_tx_core.sv` máš port:

```systemverilog
input logic frame_start_i,
```

ale aktuálne sa packet plánuje podľa `vsync_r`.

Pre HDMI packet scheduling je lepšie používať `frame_start_i`/`line_start_i`/`vblank_i`, nie hranu `vsync`.

Takže ďalší refaktor by mal byť:

```text
vsync edge packet trigger → vblank-safe packet trigger
```

---

## Kompilovateľnosť rozhraní

Medzi týmito modulmi to teraz vyzerá rozumne zosúladené:

```text
vga_hdmi_tx → hdmi_tx_core
hdmi_tx_core → hdmi_period_scheduler
hdmi_tx_core → hdmi_channel_mux
hdmi_tx_core → data_island_formatter
hdmi_tx_core → tmds_phy_ddr_aligned
```

Nevidím tam už zásadný portový nesúlad typu „core očakáva port, wrapper ho neposiela“.

Jedna vec: `vga_hdmi_tx` zatiaľ neposiela `line_start_i`, lebo `hdmi_tx_core` ho zatiaľ nemá. To nie je chyba, ale ďalší potrebný krok.

---

## Čo by som spravil hneď teraz

### Krok 1: drž `ENABLE_DATA_ISLAND=0` ako referenčný test

Over:

```text
farby správne
obraz bez posunu
TMDS video stabilné
```

Toto už pravdepodobne máš.

---

### Krok 2: `ENABLE_DATA_ISLAND=1`, ale packet plánovať bezpečne

Doplniť `line_start_i` a nahradiť `vsync rising edge` trigger.

Toto je teraz podľa mňa najdôležitejšia oprava.

---

### Krok 3: urobiť testovací režim „packet iba vo vblank“

Dočasne zakáž data islandy počas horizontálneho blankingu aktívnych riadkov:

```systemverilog
allow_packet = vblank_r && hblank_rr;
```

Ak obraz prestane byť posunutý, vieš, že problém je v umiestnení packetu.

Neskôr môžeš povoliť aj hblank počas active frame, ale až po overení.

---

### Krok 4: simulácia `hdmi_tx_core`

V testbenchi assertovať:

```text
packet_start je mimo DE
packet_pop má presne 32 pulzov
DATA_PAYLOAD nikdy nezasiahne do DE
VIDEO_PREAMBLE má 8 cyklov
VIDEO_GB má 2 cykly
VIDEO začína zarovnane s prvým platným video_ch*
```

A hlavne pri frame začiatku:

```text
data island nie je v okolí VSYNC prechodu, ak ho tam nechceš
```

---

## Cesta k plnému HDMI

Aktuálne máš:

```text
HDMI video + AVI InfoFrame path
```

Na plné HDMI treba doplniť tieto vrstvy:

### 1. Packet arbiter

Teraz máš pevne len AVI packet.

Potrebný ďalší blok:

```text
hdmi_packet_arbiter
```

Zdroje:

```text
GCP
AVI InfoFrame
Audio InfoFrame
ACR
Audio Sample Packet
SPD/Vendor voliteľne
```

Prvý jednoduchý plán:

```text
každý frame:
  slot 1: GCP
  slot 2: AVI
```

Neskôr:

```text
periodicky ACR
audio sample podľa FIFO
audio infoframe pri zmene konfigurácie
```

---

### 2. GCP packet

Implementuj `gcp_packet_builder`.

Pre basic 8-bit RGB bude väčšina polí nulová, ale je to dobrý ďalší packet pred audio.

---

### 3. ACR packet

Pre audio potrebuješ ACR:

```text
N/CTS
```

Prvý cieľ:

```text
48 kHz, 2ch LPCM
N = 6144
CTS podľa pixel clocku / TMDS clocku
```

Najprv tabuľkové hodnoty pre tvoje módy.

---

### 4. Audio InfoFrame

`infoframe_builder` už má podporu pre Audio InfoFrame, ale nie je zapojený.

Po GCP + AVI pridaj:

```text
Audio InfoFrame raz za frame alebo pri zmene audio cfg
```

---

### 5. Audio sample packetizer

Až potom pridaj:

```text
audio_sample_packetizer
```

Prvý test nerob cez I2S. Urob interný tón:

```text
1 kHz test tone
48 kHz
2ch LPCM
16-bit alebo 24-bit
```

Až keď hrá interný tón, pripoj I2S/PCM vstup a async FIFO.

---

### 6. EDID/DDC

Na úplnú univerzálnosť neskôr:

```text
DDC I2C master
EDID parser
supported VIC
audio capability parser
```

Ale EDID by som nerobil predtým, než máš basic audio cez fixnú konfiguráciu.

---

## Prioritný zoznam

Najbližšie odporúčam:

```text
1. Pridať line_start_i do vga_hdmi_tx a hdmi_tx_core.
2. Packet pending generovať až v bezpečnom vblank okne, nie na vsync hrane.
3. Otestovať ENABLE_DATA_ISLAND=1, či zmizne 2-riadkový posun.
4. Simulačne overiť 32 payload cyklov data islandu a preamble/GB sekvenciu.
5. Pridať jednoduchý packet arbiter.
6. Pridať GCP + AVI ako dva data islandy za frame.
7. Až potom začať ACR/audio.
```

---

## Zhrnutie

Aktuálne súbory už sú v dobrom stave pre prvý HDMI data-island bring-up. Najväčší ostávajúci praktický problém nie je farba ani PHY, ale **kedy sa packet vkladá**.

Najpravdepodobnejší dôvod 2-riadkového posunu pri `ENABLE_DATA_ISLAND=1` je:

```text
packet_pending je naviazaný na VSYNC hranu
```

a nie na bezpečné vertical-blank okno.

Ďalšia najlepšia úprava je preto jasná: **pridať `line_start_i` a plánovať AVI data island až po niekoľkých riadkoch vo vblanku**. Potom pokračovať na GCP, packet arbiter a až následne audio.
