Áno. Ak chceš ísť z aktuálneho **DVI-compatible HDMI video jadra** na **plne štandardný HDMI s data island/audio**, odporúčam postupovať po vrstvách. HDMI špecifikácia je licencovaná; pre komerčne korektnú implementáciu a CTS potrebuješ oficiálne HDMI Adopter materiály. HDMI Forum uvádza, že implementácia HDMI štandardu vyžaduje byť HDMI Adopter a produkty majú spĺňať aktuálnu HDMI špecifikáciu a CTS. ([HDMI Forum][1])

Nižšie je praktický technický postup, ako sa tam dostať z tvojho aktuálneho kódu.

---

# 0. Najprv si zafixuj cieľ verzie

Za rozumný cieľ by som zvolil:

```text
HDMI TX v1:
- RGB 4:4:4, 8 bit/component
- DVI-compatible video path
- AVI InfoFrame
- Audio InfoFrame
- General Control Packet
- Audio Clock Regeneration packet
- Audio Sample packet
- 2-channel LPCM 48 kHz, 16/24 bit
- bez deep color
- bez YCbCr
- bez HDCP
- bez 3D/VRR/HDR
```

To je stále dosť veľký krok, ale je to zvládnuteľný „basic HDMI source“.

Nepokúšal by som sa hneď o:

```text
- HDMI 2.x high bandwidth features
- FRL
- HDR metadata
- multi-channel compressed audio
- ARC/eARC
- HDCP
```

Najprv sprav korektný TMDS HDMI 1.x-style data-island/audio základ.

---

# 1. Stabilizuj DVI video vrstvu

Toto je podmienka pred všetkým ostatným.

Musí byť stabilné:

```text
video_timing_generator
    ↓
video_stream_frame_aligner
    ↓
hdmi_tx_core, ENABLE_DATA_ISLAND=0
    ↓
tmds_phy_ddr_aligned
```

Over:

```text
- stabilný obraz bez výpadkov
- správne HS/VS polarity
- správne DE
- žiadny posun o pixel
- word-aligned TMDS serializer
- TMDS encoder overený referenčným modelom
```

Kým toto nie je stabilné, audio/data islands nerieš. Ak je chyba v TMDS video alebo PHY, data-island debug bude prakticky nemožný.

---

# 2. Doplň do video timing vrstvy informácie potrebné pre HDMI scheduler

Tvoj `hdmi_tx_core` by nemal hádať `vblank` z `vsync`. Potrebuje explicitné timing signály.

Rozšír vstup `hdmi_tx_core` o:

```systemverilog
input logic hblank_i,
input logic vblank_i,
input logic frame_start_i,
input logic line_start_i,
input logic [15:0] h_cnt_i,
input logic [15:0] v_cnt_i,
input logic [15:0] blank_remaining_i
```

`blank_remaining_i` je veľmi dôležitý. Scheduler musí vedieť, či sa mu data island zmestí do blankingu.

Napríklad:

```systemverilog
assign blank_remaining_o =
  de_o ? 16'd0 :
  H_TOTAL - h_cnt_o;
```

Presnejšie ho sprav tak, aby reprezentoval počet pixel-clockov do začiatku ďalšej active video oblasti.

---

# 3. Uprav `hdmi_period_scheduler`

Aktuálny scheduler má dobrú kostru:

```text
CONTROL
DATA_PREAMBLE
DATA_GB_LEAD
DATA_PAYLOAD
DATA_GB_TRAIL
VIDEO
```

Ale pre štandardnejší HDMI potrebuje:

```text
- nesmie začať data island, ak sa nezmestí do blankingu
- musí generovať presnú dĺžku preambuly
- musí generovať leading/trailing guard band
- musí vedieť dĺžku packetu/data islandu
- musí dávať consume signál formatteru, nie priamo packet byte streamu
```

Pridaj:

```systemverilog
input  logic [15:0] blank_remaining_i;
input  logic        data_island_request_i;
input  logic [5:0]  data_island_len_i;

output logic        data_island_start_o;
output logic        data_island_consume_o;
output logic        data_island_active_o;
```

Podmienka štartu:

```systemverilog
localparam int PREAMBLE_LEN = 8;
localparam int LEAD_GB_LEN  = 2;
localparam int TRAIL_GB_LEN = 2;

wire [15:0] island_total_len =
    PREAMBLE_LEN + LEAD_GB_LEN + data_island_len_i + TRAIL_GB_LEN;

if (hblank_i &&
    data_island_request_i &&
    blank_remaining_i >= island_total_len) begin
  start_data_island = 1'b1;
end
```

Pre začiatok môžeš `data_island_len_i` fixnúť na 32 pixel periods, ale rozhranie si priprav všeobecne.

---

# 4. Pridaj nový blok `data_island_formatter`

Toto je najdôležitejší chýbajúci blok.

Teraz máš približne:

```text
packet_scheduler byte
    ↓
TERC4 ch0/ch1
```

To nestačí.

Správna vrstva má byť:

```text
packet_scheduler / packet source
    ↓
data_island_formatter
    ↓
3× 4-bit nibble per TMDS channel
    ↓
TERC4 encoder × 3
```

HDMI data island nepremapováva obyčajný byte lineárne na dva kanály. Počas data island periódy sa používajú TERC4 symboly; verejný HDMI 1.3 text opisuje, že každý z troch TMDS kanálov prenáša 10-bitové znaky zakódované z 4-bitového vstupu pomocou TERC4. ([fpga.mit.edu][2])

Navrhované rozhranie:

```systemverilog
typedef struct packed {
  logic [3:0] ch0;
  logic [3:0] ch1;
  logic [3:0] ch2;
  logic       valid;
  logic       first;
  logic       last;
} hdmi_di_symbol_t;
```

Modul:

```systemverilog
module data_island_formatter (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic start_i,
  input  logic consume_i,

  input  hdmi_packet_t packet_i,
  input  logic         packet_valid_i,
  output logic         packet_ready_o,

  output hdmi_di_symbol_t di_symbol_o,
  output logic            di_valid_o,
  output logic            di_done_o
);
```

---

# 5. Zaveď jednotný HDMI packet descriptor

Namiesto viacerých samostatných `header_avi`, `payload_avi`, `len_avi`, `header_spd` portov by som zaviedol jednotný interný typ:

```systemverilog
typedef struct packed {
  logic [7:0] hb0;
  logic [7:0] hb1;
  logic [7:0] hb2;
  logic [7:0] pb [0:27];   // podľa interného layoutu
  logic [5:0] pb_len;
  logic       valid;
} hdmi_packet_t;
```

Pozor: konkrétny HDMI data-island packet má štruktúru hlavičky a tela s ECC. AMD HDMI dokumentácia napríklad uvádza, že HDMI data island packet má 4-bajtovú packet header časť, kde sú 3 bajty dát a 1 bajt BCH ECC, a telo pozostáva zo štyroch subpacketov, každý so 7 bajtmi dát a 1 bajtom BCH ECC. ([AMD Documentation][3])

Preto odporúčam mať dve úrovne:

```text
hdmi_packet_t
    = logický packet: HB0/HB1/HB2 + payload bytes

hdmi_data_island_frame_t
    = fyzický data-island layout: header ECC + subpacket ECC + channel mapping
```

---

# 6. Implementuj BCH/ECC generátory

Toto je nutné pre štandardné HDMI data islands.

Potrebuješ minimálne:

```text
packet header ECC:
  24 bit header data → 8 bit BCH parity

packet body ECC:
  56 bit subpacket data → 8 bit BCH parity
```

Zaveď moduly:

```systemverilog
module hdmi_bch_ecc_header (
  input  logic [23:0] data_i,
  output logic [7:0]  ecc_o
);

module hdmi_bch_ecc_subpacket (
  input  logic [55:0] data_i,
  output logic [7:0]  ecc_o
);
```

Toto musíš implementovať presne podľa HDMI špecifikácie. Bez toho síce niektoré monitory môžu niečo tolerovať, ale nebude to štandardne správny HDMI data island.

---

# 7. Implementuj presný data-island mapping

Po ECC musíš fyzicky namapovať packet do TMDS kanálov.

Verejné protokolové poznámky opisujú, že počas data islandu channel 0 nesie okrem zakódovaných HSYNC/VSYNC aj packet header bity a kanály 1 a 2 nesú packet data; packet má 32 pixelových periód a je chránený BCH ECC. ([Prodigy Technovations][4])

Teda nestačí:

```text
byte[3:0] → ch0
byte[7:4] → ch1
0         → ch2
```

Potrebný je blok, ktorý pre každý data-island pixel index `0..31` vyprodukuje:

```systemverilog
di_symbol.ch0 = ...
di_symbol.ch1 = ...
di_symbol.ch2 = ...
```

Prakticky:

```systemverilog
case (di_index)
  0: begin
    // header/subpacket bit group mapping
  end
  ...
  31: begin
    // posledná data-island symbol period
  end
endcase
```

Tento blok bude najviac „špecifikačný“. Odporúčam ho písať tabuľkovo a veľmi dobre testovať.

---

# 8. Uprav `hdmi_channel_mux`

Dnes je dobrý ako mux, ale pre plné HDMI potrebuje presné hodnoty pre:

```text
- control period
- data island preamble
- video guard band
- data island leading guard band
- data island trailing guard band
```

Tiež budeš potrebovať control signály pre kanály 1 a 2, nielen pevné `2'b00`.

Verejný HDMI 1.3 text ukazuje, že control signály pre TMDS kanály sú priradené ako: channel 0 nesie HSYNC/VSYNC, channel 1 nesie CTL0/CTL1, channel 2 nesie CTL2/CTL3, a control encoding mapuje dvojicu bitov na 10-bitové control symboly. ([fpga.mit.edu][2])

Preto zaveď:

```systemverilog
logic [1:0] ctl_ch0;
logic [1:0] ctl_ch1;
logic [1:0] ctl_ch2;
```

A v preambule nastavuj `ctl_ch1/ctl_ch2` podľa toho, či ideš do video data period alebo data island period.

---

# 9. Najprv pridaj AVI InfoFrame

Po vybudovaní `data_island_formatter` začni najjednoduchším packetom:

```text
AVI InfoFrame
```

Tvoj `infoframe_builder` už má dobrý základ. Potrebuješ ho pripojiť takto:

```text
infoframe_builder
    ↓
packet_source_avi
    ↓
packet_arbiter
    ↓
data_island_formatter
    ↓
TERC4
```

AVI InfoFrame posielaj napríklad raz za frame počas vertical blankingu.

Pridaj jednoduchý arbiter:

```systemverilog
priority:
1. GCP
2. AVI InfoFrame
3. Audio InfoFrame
4. ACR
5. Audio Sample
```

Na začiatok môžeš:

```text
frame_start → request AVI packet
```

a scheduler ho vloží do najbližšieho bezpečného blanking okna.

---

# 10. Potom pridaj General Control Packet

GCP je potrebný najmä pre niektoré HDMI vlastnosti, ale aj ako súčasť robustnej HDMI infraštruktúry.

Sprav:

```systemverilog
module gcp_packet_builder (
  input  logic avmute_i,
  input  logic clear_avmute_i,
  input  logic [3:0] color_depth_i,
  output hdmi_packet_t packet_o
);
```

Pre základný 8-bit RGB režim bude väčšina polí nulová.

---

# 11. Potom pridaj Audio Clock Regeneration: N/CTS

Pre audio musí prijímač vedieť zrekonštruovať audio clock. Na to sú ACR pakety s hodnotami `N` a `CTS`.

Sprav blok:

```systemverilog
module hdmi_acr_generator (
  input  logic        pix_clk_i,
  input  logic        rst_ni,

  input  audio_rate_e audio_rate_i,
  input  logic [31:0] tmds_clock_hz_i,

  output logic [19:0] n_o,
  output logic [19:0] cts_o,
  output logic        acr_packet_req_o
);
```

Pre prvú verziu by som použil tabuľkové hodnoty pre bežné režimy:

```text
pixel clock 25.175 MHz / 27 MHz / 74.25 MHz / 148.5 MHz
audio 48 kHz
```

Neskôr môžeš pridať výpočet alebo meranie CTS.

---

# 12. Pridaj Audio InfoFrame

Tvoj `infoframe_builder` už vie `INFO_AUDIO`.

Použi základ:

```text
2 channels
LPCM
sample size podľa konfigurácie
sample frequency podľa konfigurácie
```

Posielaj ho:

```text
- pri štarte
- pri zmene audio konfigurácie
- periodicky, napr. raz za frame
```

---

# 13. Pridaj audio vstupnú vrstvu

Nemiešaj I2S prijímač priamo s HDMI packetizerom.

Správna štruktúra:

```text
i2s_rx / pcm_stream
    ↓
audio_sample_fifo
    ↓
audio_sample_packetizer
    ↓
packet_arbiter
    ↓
data_island_formatter
```

Rozhranie pre audio sample stream:

```systemverilog
typedef struct packed {
  logic signed [23:0] left;
  logic signed [23:0] right;
  logic               valid;
} pcm_stereo_sample_t;
```

Ak audio prichádza v inej clock doméne, použi async FIFO:

```text
audio_clk_i → async FIFO → pix_clk_i
```

---

# 14. Implementuj Audio Sample Packetizer

Pre základné 2-kanálové LPCM:

```text
PCM sample FIFO
    ↓
IEC 60958 / channel status info
    ↓
HDMI Audio Sample Packet
```

Sprav modul:

```systemverilog
module hdmi_audio_sample_packetizer (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic [23:0] pcm_l_i,
  input  logic [23:0] pcm_r_i,
  input  logic        pcm_valid_i,
  output logic        pcm_ready_o,

  input  hdmi_audio_cfg_t audio_cfg_i,

  output hdmi_packet_t packet_o,
  output logic         packet_valid_o,
  input  logic         packet_ready_i
);
```

Na začiatok podporuj len:

```text
2ch LPCM
48 kHz
16 alebo 24 bit
```

Až potom 44.1/32 kHz.

---

# 15. Packet arbiter

Keď budeš mať viac zdrojov packetov, potrebuješ arbiter:

```text
AVI InfoFrame source
Audio InfoFrame source
GCP source
ACR source
Audio Sample source
User/vendor packet source
        ↓
packet_arbiter
        ↓
data_island_formatter
```

Pravidlá priority:

```text
1. ACR, ak je čas ho poslať
2. Audio Sample, ak FIFO hrozí naplnením
3. AVI InfoFrame raz za frame
4. Audio InfoFrame raz za frame / pri zmene
5. SPD/Vendor/User packet
```

Nech arbiter vyberie vždy jeden `hdmi_packet_t`.

---

# 16. Rozšír `hdmi_tx_core` iba cez čisté rozhrania

Nedávaj všetko priamo do `hdmi_tx_core` ako obrovský modul. Lepšie:

```text
hdmi_tx_core
├── hdmi_period_scheduler
├── hdmi_packet_arbiter
├── data_island_formatter
├── tmds_video_encoder
├── tmds_control_encoder
├── terc4_encoder
└── hdmi_channel_mux
```

Top-level rozhranie:

```systemverilog
input  hdmi_packet_t aux_packet_i,
input  logic         aux_packet_valid_i,
output logic         aux_packet_ready_o,

input  pcm_sample_t  audio_sample_i,
input  logic         audio_valid_i,
output logic         audio_ready_o
```

Alebo môžeš mať packet/audio subsystém mimo core a do core posielať už `di_symbol`.

Najčistejšie delenie:

```text
hdmi_tx_core_video
hdmi_tx_packet_engine
hdmi_tx_data_island_encoder
hdmi_tx_symbol_mux
```

---

# 17. Testovanie po vrstvách

Toto je kritické. Nerob debug rovno na monitore.

## Test 1: TERC4

```text
4-bit input 0..15 → očakávaný 10-bit output
```

## Test 2: BCH/ECC

```text
známe header/payload hodnoty → očakávaný ECC
```

## Test 3: data_island_formatter

Vstup:

```text
známy packet HB/PB
```

Výstup:

```text
32 symbol periods × 3 channels × 4-bit nibbles
```

Porovnať s referenčnou tabuľkou.

## Test 4: period_scheduler

Scenáre:

```text
packet pending na začiatku blankingu
packet pending neskoro v blankingu
packet pending počas active video
viac packetov za sebou
```

Over:

```text
nikdy nezasiahne do active video
consume_i len počas payload
```

## Test 5: AVI InfoFrame na monitore

Keď analyzátor alebo monitor ukáže správne HDMI metadata, pokračuj.

## Test 6: ACR

Over frekvenciu audio clock recovery packetov a hodnoty N/CTS.

## Test 7: Audio Sample Packet

Najprv generuj jednoduchý tón:

```text
1 kHz sine alebo square wave
48 kHz
2ch LPCM
```

---

# 18. Odporúčané poradie implementácie

Najpraktickejšie poradie:

```text
Fáza 1:
  DVI video, ENABLE_DATA_ISLAND=0
  stabilný obraz

Fáza 2:
  TERC4 encoder testbench
  control/preamble/guard-band mux testbench

Fáza 3:
  BCH/ECC header/subpacket generators

Fáza 4:
  data_island_formatter pre jeden dummy packet

Fáza 5:
  AVI InfoFrame cez data island

Fáza 6:
  GCP

Fáza 7:
  Audio InfoFrame

Fáza 8:
  ACR packet N/CTS

Fáza 9:
  Audio sample packetizer pre 2ch LPCM 48 kHz

Fáza 10:
  I2S/PCM vstup + async FIFO

Fáza 11:
  EDID/DDC čítanie a konfigurácia podľa sinku
```

---

# 19. EDID/DDC pridaj až po basic audio

EDID je dôležitý pre univerzálnosť, ale neblokuje prvý bring-up.

Neskôr pridaj:

```text
DDC I2C master
EDID reader
CEA extension parser
supported VIC list
audio capabilities
speaker allocation
preferred timing
```

Potom budeš vedieť dynamicky nastaviť:

```text
VIC
aspect ratio
audio channels
sample rates
color format
```

CTA-861 definuje pravidlá pre digitálne video formáty a InfoFrame/metadata ekosystém pre spotrebnú elektroniku; aktuálne špecifikácie sú distribuované cez CTA. ([Consumer Technology Association®][5])

---

# 20. Čo by som nemenil teraz

Nerobil by som ešte:

```text
- deep color
- YCbCr 4:2:2
- HDR InfoFrame
- Vendor Specific InfoFrame pre 4K/3D
- HDCP
- FRL
- eARC
```

Tieto veci pridaj až keď máš spoľahlivý basic HDMI TX.

---

# 21. Finálny cieľ architektúry

Cieľový blokový diagram:

```text
video_timing_generator
        ↓
timed RGB888 video
        ↓
tmds_video_encoder ×3
        ↓
                    ┌──────────────────────┐
audio_pcm_fifo ────▶│ audio_packetizer      │
infoframe_builder ─▶│ packet_arbiter        │
gcp_builder ───────▶│ data_island_formatter │
acr_generator ─────▶│ BCH/ECC + mapping     │
                    └──────────┬───────────┘
                               ↓
                         TERC4 encoder ×3

control_encoder ×3
        ↓
hdmi_channel_mux
        ↓
3× 10-bit TMDS words
        ↓
tmds_phy_ddr_aligned / vendor OSERDES
```

---

## Zhrnutie

Tvoja aktuálna architektúra je už dobrý základ. Na plný HDMI potrebuješ doplniť hlavne tieto bloky:

```text
1. blank_remaining-aware period scheduler
2. data_island_formatter
3. BCH/ECC generátory
4. presný data island channel mapping
5. packet arbiter
6. AVI/GCP/Audio InfoFrame packet sources
7. ACR N/CTS generator
8. audio sample packetizer
9. audio FIFO / I2S alebo PCM vstup
10. neskôr EDID/DDC
```

Najbližší konkrétny krok by som zvolil: **implementuj `data_island_formatter` + BCH/ECC a otestuj jeden AVI InfoFrame bez audio**. Audio pridaj až po tom, čo vieš spoľahlivo poslať korektný data island packet.

[1]: https://hdmiforum.org/specifications/?utm_source=chatgpt.com "SPECIFICATIONS"
[2]: https://fpga.mit.edu/6205/_static/F23/common_files/week04/CEC_HDMI_Specification.pdf?utm_source=chatgpt.com "HDMI Specification 1.3"
[3]: https://docs.amd.com/r/en-US/pg351-v-hdmi-rxss1/AUX-Packets?utm_source=chatgpt.com "AUX Packets - 1.2 English - PG351"
[4]: https://www.prodigytechno.com/hdmi-protocol?utm_source=chatgpt.com "HDMI Protocol"
[5]: https://shop.cta.tech/products/cta-861?utm_source=chatgpt.com "CTA 861"
