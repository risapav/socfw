To, že **Test A, B aj C nepomohli**, je veľmi užitočné. Znamená to, že pôvodná hypotéza:

```text
de / hblank / blank_remaining pipeline mismatch
```

pravdepodobne **nie je hlavná príčina** posunu.

Aktuálny stav by som prepísal takto:

```text
DATA_ISLAND=0                      → obraz OK
DATA_ISLAND=1, GCP=0, AVI=0         → obraz viditeľný, ale posunutý doprava / zelená čiara
zmena de zdroja                     → nepomohla
zmena hs/vs zdroja                  → nepomohla
zmena hblank/blank_remaining delay  → ovplyvnila posun, ale neopravila
period_d1 → period_d2               → nepomohlo
```

Z toho vyplýva, že problém je pravdepodobne v tom, že pri `ENABLE_DATA_ISLAND=1` sa aktivuje **iný video period model** než pri `ENABLE_DATA_ISLAND=0`.

---

## Najpravdepodobnejší nový podozrivý

Pri `ENABLE_DATA_ISLAND=1` používaš HDMI period scheduler, ktorý generuje:

```text
CONTROL
VIDEO_PREAMBLE
VIDEO_GB
VIDEO
DATA_PREAMBLE
DATA_GB
DATA_PAYLOAD
DATA_GB_TRAIL
```

Aj keď nemáš žiadne GCP/AVI pakety, stále sa pravdepodobne používa HDMI režim s:

```text
VIDEO_PREAMBLE + VIDEO_GB pred aktívnym videom
```

Pri `ENABLE_DATA_ISLAND=0` môže ísť jadro viac „DVI-like“:

```text
de=1 → VIDEO
de=0 → CONTROL
```

Takže rozdiel môže byť práve:

```text
HDMI video preamble / video guard band timing
```

nie `blank_remaining`.

Zelená čiara vľavo veľmi sedí na to, že prvý 1–N pixelov riadku nie je skutočný pixel 0, ale oneskorený / nesprávne zarovnaný pixelový stream po prechode:

```text
VIDEO_GB → VIDEO
```

---

# Najbližší test: vypnúť VIDEO_PREAMBLE / VIDEO_GB v 2A

Sprav diagnostický parameter, napríklad:

```systemverilog
parameter bit DEBUG_DISABLE_VIDEO_GB = 0;
```

alebo jednoduchšie:

```systemverilog
parameter bit DEBUG_DVI_VIDEO_WHEN_NO_PACKETS = 0;
```

Cieľ testu:

```text
ENABLE_DATA_ISLAND=1
GCP=0
AVI=0
ale VIDEO sa správa ako DVI:
  de=1 → VIDEO
  de=0 → CONTROL
bez VIDEO_PREAMBLE a VIDEO_GB
```

Ak tento test odstráni zelenú čiaru, koreň je potvrdený:

```text
chyba je vo VIDEO_PREAMBLE / VIDEO_GB / VIDEO boundary pri HDMI period scheduleri
```

Nie v data payload, GCP, AVI, blank_remaining ani audio.

---

## Variant jednoduchého diagnostického patchu

V `hdmi_tx_core.sv` alebo v scheduleri urob dočasný bypass:

```systemverilog
logic no_packets_enabled;

assign no_packets_enabled =
  !ENABLE_GCP_PACKET &&
  !ENABLE_AVI_PACKET &&
  !ENABLE_ACR_PACKET &&
  !ENABLE_AUDIO_INFOFRAME &&
  !ENABLE_AUDIO_SAMPLE;
```

Potom pre test:

```systemverilog
if (ENABLE_DATA_ISLAND && no_packets_enabled && DEBUG_DVI_VIDEO_WHEN_NO_PACKETS) begin
  period = de_r ? HDMI_PERIOD_VIDEO : HDMI_PERIOD_CONTROL;
end
```

Ale čistejšie je spraviť to v scheduleri ako debug režim.

### Očakávanie

```text
Ak obraz bude OK:
  problém je HDMI video preamble/guard timing.

Ak obraz ostane posunutý:
  problém je niekde inde v ENABLE_DATA_ISLAND vetve mimo scheduler period modelu.
```

---

# Druhý test: VIDEO_GB only boundary

Ak sa potvrdí, že problém je pri HDMI video boundary, rozbi to ďalej:

```text
V1: CONTROL → VIDEO bez preamble/GB
V2: VIDEO_PREAMBLE → VIDEO bez VIDEO_GB
V3: VIDEO_GB → VIDEO bez VIDEO_PREAMBLE
V4: VIDEO_PREAMBLE → VIDEO_GB → VIDEO
```

Interpretácia:

```text
V1 PASS, V2 FAIL:
  problém je VIDEO_PREAMBLE.

V1 PASS, V3 FAIL:
  problém je VIDEO_GB.

V1/V2/V3 PASS, V4 FAIL:
  problém je ich kombinované načasovanie alebo dĺžka.
```

---

# Veľmi dôležitá kontrola: VIDEO_GB môže zasahovať do aktívneho videa

V sim pridaj tvrdý assertion:

```systemverilog
if (period_mux_stage == HDMI_PERIOD_VIDEO_GB && de_output_aligned) begin
  $error("VIDEO_GB overlaps active video");
end

if (period_mux_stage == HDMI_PERIOD_VIDEO_PREAMBLE && de_output_aligned) begin
  $error("VIDEO_PREAMBLE overlaps active video");
end
```

A opačne:

```systemverilog
if (de_output_aligned && period_mux_stage != HDMI_PERIOD_VIDEO) begin
  $error("Active video is not VIDEO period");
end
```

Už máš podobné kontroly, ale teraz treba overiť presne **output stage**, nie scheduler stage.

---

# Ešte jeden silný kandidát: RGB pixel stream je oneskorený voči `de`

Aj keď si menil `vga_de_i`, stále môže platiť:

```text
de je zarovnané,
ale RGB pixel hodnoty sú o 1–N cyklov mimo
```

Zelená čiara môže byť prvý pixel z predchádzajúceho riadku alebo default/fill pixel.

Preto v sim aj SignalTap sleduj:

```text
vga_de_i
vga_r_i/g_i/b_i
de_r
rgb_r/g/b po registrácii v hdmi_tx_core
period_d1
tmds_video_encoder input
```

Najmä prvých 8 aktívnych pixelov každého riadku.

V 2A a DVI baseline musia byť rovnaké:

```text
riadok y, pixel x=0..7
```

Ak v 2A ide pri x=0 iná RGB hodnota než v baseline, problém je RGB/DE alignment, nie TMDS.

---

# FPGA overenie bez SignalTapu

Ak nechceš hneď SignalTap, urob vizuálny test s jednoduchým patternom:

```text
pixel x=0..7 vždy červený
pixel x=8..15 vždy modrý
zvyšok zelený / gradient
```

Alebo úplne jednoduché:

```text
x = 0      biela
x = 1      červená
x = 2      zelená
x = 3      modrá
x >= 4     čierna / gradient
```

Tým hneď uvidíš, koľko pixelov sa stratí alebo posunie.

Teraz máš možno pattern, kde zelená čiara vzniká nejasne z generátora. Špeciálny „edge marker“ pattern ti dá presný počet pixelov posunu.

---

# Čo by som nerobil teraz

Neriešil by som teraz:

```text
GCP obsah
AVI checksum
ACR
audio
VBLANK_ONLY
GCP_FRAME_PERIOD
```

Kým `2A no packet` nie je pixelovo identický s DVI baseline, všetky packet testy budú zavádzajúce.

---

# Odporúčaný ďalší postup

## Krok 1

Pridaj debug režim:

```text
DEBUG_DVI_VIDEO_WHEN_NO_PACKETS=1
```

Pri:

```text
ENABLE_DATA_ISLAND=1
GCP=0
AVI=0
```

nech sa výstup správa ako DVI:

```text
de → VIDEO
!de → CONTROL
```

Bez HDMI video preamble a video guard band.

## Krok 2

Ak to opraví obraz, rozbi VIDEO preamble/GB na V1–V4 testy.

## Krok 3

Pridaj edge-marker obrazový pattern, aby si vedel presne zmerať počet pixelov posunu.

## Krok 4

Až keď `2A` bude úplne čistý, pokračuj:

```text
T2
T3
2B
2C
```

---

## Krátky záver

Keďže zmeny `de`, `hblank/blank_remaining` ani `period_d1/d2` problém neodstránili, najpravdepodobnejšie je, že posun vzniká pri samotnom **HDMI video period modeli**:

```text
VIDEO_PREAMBLE / VIDEO_GB / VIDEO boundary
```

Najlepší ďalší test je preto:

```text
ENABLE_DATA_ISLAND=1, ale no-packet režim vynútiť ako DVI video path.
```

Ak tento test prejde, vieš, že musíš opraviť časovanie VIDEO_PREAMBLE/VIDEO_GB pred aktívnym videom.
