Vidím, že táto sada je už veľmi slušne zdokumentovaná a konzistentná so smerom, ktorý sme chceli. Podľa `HDMI_STATUS.md` máte aktuálne: `GCP + AVI` packet cestu, `data_island_formatter`, 8-stavový scheduler, `VIDEO_TRIG=10`, dynamický CH0 data guard band a `tmds_phy_ddr_aligned`; zároveň sú pre scheduler, formatter a BCH/ECC uvedené úspešné testbenche.

## Aktuálny stav

Projekt je teraz vo fáze:

```text
HDMI video + GCP + AVI InfoFrame cez data island
```

To už nie je len DVI-compatible výstup. Máte základný HDMI packet engine:

```text
gcp_packet_builder
infoframe_builder AVI
hdmi_packet_arbiter
data_island_formatter
TERC4 ×3
hdmi_channel_mux
```

V status dokumente je packetová cesta popísaná ako `GCP → AVI per frame`, pričom data-island časť používa BCH/ECC formatter a 32-symbolový data payload.

Najdôležitejšie: `VIDEO_TRIG=10` je rozumne zdokumentovaný a analyticky odôvodnený cez pipeline oneskorenia. Podľa dokumentácie sa `VIDEO` na výstupe muxu stretne s prvým TMDS pixelom pri `T+13`, čo sedí s `blank_remaining_rr = 10`.

---

## Čo by som teraz nerobil

Neskákal by som ešte na audio. Najprv treba uzavrieť posledný známy video/data-island problém:

```text
2-riadkový vertikálny posun
```

V status dokumente je tento problém priamo označený ako otvorený: prvé dva riadky sú nevalidné alebo je obraz posunutý nadol o 2 riadky. Ako hypotézy sú uvedené frame aligner, data island na poslednej vblank línii alebo oneskorený začiatok generovania pixelov.

To je aktuálne priorita číslo 1.

---

## Najbližší krok: izolovať príčinu 2-riadkového posunu

Spravil by som testy v tomto poradí:

### Test A — `ENABLE_DATA_ISLAND=0`

Cieľ:

```text
overiť, či 2-riadkový posun existuje aj bez GCP/AVI
```

Výsledky:

```text
posun zmizne  → problém je data-island/scheduler/packet timing
posun ostane  → problém je video pipeline: frame_aligner, generator, vga_output_adapter, VTG
```

### Test B — `ENABLE_DATA_ISLAND=1`, ale `packet_valid=0`

Teda nech scheduler stále robí `VIDEO_PREAMBLE → VIDEO_GB → VIDEO`, ale bez data islandu.

Výsledky:

```text
posun zmizne  → problém je data island insertion
posun ostane  → problém je video preamble/video trigger alebo video pipeline
```

### Test C — obísť `video_stream_frame_aligner`

Na jeden build použi priamy pattern generovaný v timed video doméne, bez FIFO/frame alignera.

Cieľ:

```text
zistiť, či frame_aligner naozaj potrebuje 2 riadky na rozbeh
```

Ak sa posun stratí, hľadaj v `video_stream_frame_aligner` a v tom, kedy dostáva `SOF` oproti `frame_start`.

---

## Čo by som doplnil do simulácie

Status už odporúča simulovať celý reťazec:

```text
VTG → frame_aligner → vga_output_adapter → hdmi_tx_core
```

pre prvé tri aktívne línie. S tým plne súhlasím.

Do testbenchu by som pridal tieto signály:

```text
vtg.frame_start
vtg.line_start
vtg.pixel_req
vtg.de
aligner.s_axis_sof
aligner.s_axis_eol
aligner.s_axis_eof
aligner.pixel_take
aligner.pixel_loaded
vga_output.active_video_o
hdmi.de_r
hdmi.period
hdmi.period_d1
hdmi.packet_start
hdmi.packet_pop
hdmi.ch0_o/ch1_o/ch2_o
```

A assertoval by som:

```text
prvý aktívny pixel frame má byť pixel (x=0,y=0)
prvý EOL musí sedieť s last_active_x_req
prvý EOF musí sedieť s last_active_pixel_req
pred prvým DE nesmie byť VIDEO period aktívny príliš skoro
DATA_PAYLOAD nesmie zasiahnuť do prvého aktívneho riadku
```

---

## Po vyriešení 2-riadkového posunu

Až keď bude stabilné:

```text
video bez posunu
GCP + AVI bez posunu
správne farby
monitor drží lock
```

pokračoval by som na audio.

Poradie:

```text
1. ACR packet
2. Audio InfoFrame
3. Audio sample packetizer s interným tónom
4. I2S alebo PCM vstup
5. EDID/DDC
```

Váš status už uvádza ako ďalšie priority ACR s `N=6144`, potom Audio InfoFrame + Audio Sample packetizer a až potom EDID/DDC. To je správne poradie.

---

## Ďalší veľký RTL blok: ACR

Navrhol by som nový modul:

```systemverilog
module acr_packet_builder (
  input  logic [19:0] n_i,
  input  logic [19:0] cts_i,
  output logic [7:0]  hb_o [0:2],
  output logic [7:0]  pb_o [0:27]
);
```

Pre prvú verziu:

```text
48 kHz audio
N = 6144
CTS tabuľkovo podľa pixel clocku
```

Potom ho pridať ako ďalší zdroj do `hdmi_packet_arbiter`:

```text
GCP → AVI → ACR
```

A až potom:

```text
GCP → AVI → ACR → Audio InfoFrame → Audio Sample
```

---

## Zhrnutie

Aktuálny stav je už veľmi dobrý:

```text
✅ HDMI video
✅ video preamble + guard band
✅ data island preamble + guard band
✅ dynamický CH0 data guard band
✅ BCH/ECC
✅ GCP + AVI packet path
✅ testbenche pre scheduler / formatter / BCH
⚠️ otvorený 2-riadkový vertikálny posun
⏳ audio ešte nezačaté
```

Najbližší konkrétny cieľ by som dal:

```text
Uzavrieť 2-riadkový posun cez simuláciu celej video pipeline a separátne testy s/bez data islandu.
```

Až potom: **ACR packet**.
