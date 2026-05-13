Potom by som šiel z „základný HDMI TX“ na **použiteľný univerzálny HDMI subsystém**.

## 1. Zovšeobecni video módy

Keď už funguje pevný mód, napríklad 800×600 alebo 640×480, sprav konfigurovateľný timing:

```text
video_timing_config
  H_ACTIVE
  H_FP
  H_SYNC
  H_BP
  V_ACTIVE
  V_FP
  V_SYNC
  V_BP
  HSYNC_POL
  VSYNC_POL
  VIC
  aspect ratio
```

Cieľ:

```text
640×480p60
800×600p60
720p60
1080p30 alebo 1080p60 podľa FPGA/PHY možností
```

HDMI core by nemal byť natvrdo viazaný na jeden mód.

---

## 2. Prepoj VIC a AVI InfoFrame

Keď meníš video mód, musí sa meniť aj AVI InfoFrame:

```text
VIC
aspect ratio
RGB/YCbCr
quantization range
scan info
colorimetry
```

Čiže vytvor blok:

```text
hdmi_video_mode_cfg
    ↓
video_timing_generator
    ↓
avi_infoframe_builder
```

Aby sa timing a InfoFrame nikdy nerozišli.

---

## 3. EDID/DDC

Až potom pridaj čítanie EDID:

```text
DDC I2C master
    ↓
EDID reader
    ↓
CTA extension parser
    ↓
video/audio capability table
```

Najprv stačí parsovať:

```text
preferred timing
supported VIC modes
basic audio support
LPCM sample rates
speaker allocation
```

Potom môžeš automaticky vybrať najlepší podporovaný mód.

---

## 4. Režimová negociačná vrstva

Po EDID vytvor:

```text
hdmi_mode_manager
```

Úlohy:

```text
načítaj EDID
vyber video mód
nastav PLL pixel clock
nastav video timing
nastav AVI InfoFrame
nastav audio parametre
povoľ HDMI TX až po locku
```

Toto je rozdiel medzi „demo HDMI“ a praktickým HDMI vysielačom.

---

## 5. Robustné reset/clock riadenie

Doplň samostatný blok:

```text
hdmi_clock_reset_manager
```

Rieši:

```text
PLL lock
pixel clock reset
5× TMDS clock reset
audio clock reset
PHY phase alignment
soft reset pri zmene módu
```

Pri zmene video módu musí byť postup:

```text
vypnúť TX
resetovať PHY
prepnúť PLL
počkať na lock
resetovať HDMI core
spustiť timing
povoliť data islands
povoliť audio
```

---

## 6. Audio rozšírenia

Keď bude hrať 2ch 48 kHz LPCM, pridaj:

```text
44.1 kHz
32 kHz
96 kHz
24-bit samples
mute/unmute
audio FIFO level control
sample slip/drop protection
```

Neskôr:

```text
multi-channel LPCM
channel status
speaker allocation podľa EDID
```

---

## 7. Diagnostika a test režimy

Pridaj debug registre/signály:

```text
hdmi_locked
video_mode_active
packet_count_avi
packet_count_gcp
packet_count_acr
packet_count_audio
audio_fifo_level
underflow/overflow sticky flags
tmds_phy_ready
edid_valid
```

A test režimy:

```text
solid color
color bars
gradient
checkerboard
crosshair
audio tone
packet-only test
```

Toto ti výrazne zrýchli bring-up na rôznych monitoroch.

---

## 8. Formálnejšia verifikácia

Pre HDMI core by som mal minimálne testbenche:

```text
tmds_video_encoder_tb
terc4_encoder_tb
bch_ecc_tb
data_island_formatter_tb
period_scheduler_tb
packet_arbiter_tb
audio_packetizer_tb
hdmi_tx_core_tb
```

A assertovať:

```text
DATA_PAYLOAD nikdy počas DE
VIDEO_GB presne 2 cykly
VIDEO_PREAMBLE presne 8 cyklov
DATA_PAYLOAD presne 32 cyklov
packet_pop presne 32 pulzov
žiadny packet bez dostatočného blank_remaining
```

---

## 9. Zabalenie ako znovupoužiteľný core

Finálna štruktúra:

```text
hdmi_tx_core/
  hdmi_tx_video_core.sv
  hdmi_tx_packet_engine.sv
  hdmi_tx_audio_engine.sv
  hdmi_tx_tmds_encoder.sv

phy/
  tmds_phy_ddr_aligned.sv
  tmds_phy_intel.sv
  tmds_phy_xilinx.sv

video/
  video_timing_generator.sv
  video_stream_frame_aligner.sv

board/
  pll
  reset
  constraints
  top wrapper
```

Core nech zostane vendor-neutral. PHY a PLL nech sú board/vendor-specific.

---

## 10. Až úplne nakoniec rozšírené HDMI funkcie

Až keď je stabilné video + audio + EDID:

```text
YCbCr
limited range
deep color
SPD InfoFrame
Vendor Specific InfoFrame
CEC
hot-plug detect
mode switching za behu
```

HDCP, eARC a FRL by som zatiaľ neriešil.

---

Takže úplná roadmapa je:

```text
1. stabilný video + AVI
2. GCP + packet arbiter
3. ACR + Audio InfoFrame + audio samples
4. EDID/DDC
5. mode manager
6. robustné clock/reset riadenie
7. testbench + debug registre
8. zabalenie ako znovupoužiteľný HDMI TX core
9. rozšírené formáty
```

Najbližší veľký míľnik po audio je: **EDID/DDC + automatická voľba video/audio módu**.
