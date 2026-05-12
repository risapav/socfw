# HDMI implementácia — aktuálny stav (vga_test_05)

> Stav k: 2026-05-07  
> Quartus: 0 errors, 16 warnings (len historické truncation warnings)

---

## Architektúra — čo je implementované

### Vrstvy od pixelov po TMDS výstup

```
video_timing_generator
  │  de, hsync, vsync, hblank, vblank
  │  blank_remaining[15:0], frame_start
  │  last_active_x_req, last_active_pixel_req
  ▼
vga_output_adapter
  │  active_video_o, vga_r/g/b_o, vga_hs/vs_o (1 register stage)
  ▼
vga_hdmi_tx  (parameter ENABLE_DATA_ISLAND=1)
  │  RGB565 → RGB888 (kombinačné)
  │  vga_de_i = active_video_o (priamy drôt, nie cez board pin)
  │  vga_r/g/b/hs/vs_i = VGA_R/G/B/HS/VS (top-level output wire)
  ▼
hdmi_tx_core
  ├── Stage-1 input registers (de, hs, vs, hblank, vblank, blank_remaining)
  ├── Extra align reg: blank_remaining_rr, hblank_rr  (→ 3-stage blank_remaining pipeline)
  │
  ├── hdmi_period_scheduler  ──── HDMI period FSM (8 stavov)
  │     CONTROL → DATA_PREAMBLE → DATA_GB_LEAD → DATA_PAYLOAD
  │           → DATA_GB_TRAIL → CONTROL
  │     CONTROL → VIDEO_PREAMBLE → VIDEO_GB → VIDEO → CONTROL
  │     VIDEO_TRIG = 10  (blank_remaining_rr <= 10 spúšťa VIDEO_PREAMBLE)
  │
  ├── tmds_video_encoder × 3   (R, G, B; latency=2, running disparity reset)
  ├── tmds_control_encoder × 3 (ch0={vsync,hsync}, ch1=2'b00, ch2=2'b00)
  │
  ├── [gen_data_island]
  │     gcp_packet_builder     (GCP — statický, kombinačný)
  │     infoframe_builder AVI  (kombinačný, R/G/B, 4:3, full-range, VIC=0)
  │     hdmi_packet_arbiter    (GCP→AVI per frame, triggered na vsync_r rising edge)
  │     data_island_formatter  (BCH/ECC, shift-reg serializer, 32 symboly)
  │     terc4_encoder × 3      (latency=2)
  │
  └── hdmi_channel_mux  (registrovaný, 1 cyklus latency)
        CONTROL:        ctrl symboly (ch0={vsync,hsync}, ch1/ch2=ctrl(0))
        VIDEO_PREAMBLE: ch1=ctrl(2'b01) [CTL2=1,CTL3=0]
        VIDEO_GB:       ch1/ch2=TERC4(8)=0b1011001100, ch0=ctrl
        VIDEO:          video encoder výstup
        DATA_PREAMBLE:  ch1=ctrl(2'b11) [CTL2=1,CTL3=1], ch0={vs,hs}
        DATA_GB_LEAD/TRAIL: ch1/ch2=0b0100110011, ch0=TERC4({1,vsync,hsync,1})
        DATA_PAYLOAD:   TERC4 data island výstup
  ▼
tmds_phy_ddr_aligned  (clk_x_i = 5× pixel, pair_cnt 0..4, ALTDDIO_OUT)
  ▼
HDMI PMOD výstup (4× diff pair: B, G, R, CLK)
```

---

## Pipeline zarovnanie — VIDEO_TRIG

VIDEO_TRIG = 10 je analyticky overená hodnota.

**Pipeline (trigger posedge T, blank_remaining_rr = N = VIDEO_TRIG):**

| Signál | Latencia od T |
|--------|--------------|
| de_comb = 1 | T+N−3 (blank_remaining má 3 fázy) |
| de_o (VTG reg) | T+N−2 |
| active_video_o (vgaout0) | T+N−1 |
| de_r (hdmi stage-1) | T+N — encoder vidí stabilnú hodnotu 1 |
| enc stage-1 (posedge T+N+1) | T+N+1 |
| TMDS(pixel[0]) na tmds_o | T+N+2 |
| ch\*\_o pri channel_mux (posedge T+N+3) | T+N+3 |

**Period FSM (nezávisí od N):**

| Stav | Čas pri ch\*\_o |
|------|----------------|
| VIDEO_PREAMBLE na period_o | T+1 … T+8 |
| VIDEO_GB na period_o | T+9, T+10 |
| VIDEO na period_o | T+11 |
| VIDEO na period_d1 | T+12 |
| VIDEO na ch\*\_o | **T+13** |

Zarovnanie: T+N+3 = T+13 → **N = 10 = VIDEO_TRIG** ✓

Data island guard: `blank_remaining_rr >= ISLAND_TOTAL + VIDEO_TRIG = 44 + 10 = 54`

---

## Moduly — stav každého

| Modul | Súbor | Stav | Poznámka |
|---|---|---|---|
| `hdmi_pkg` | hdmi_pkg.sv | ✅ hotový | 8 period stavov, typy, enums |
| `tmds_video_encoder` | tmds_video_encoder.sv | ✅ hotový | DVI §3.3.3 algo, running disparity, latency=2 |
| `tmds_control_encoder` | tmds_control_encoder.sv | ✅ hotový | 4 TMDS control slová, latency=2 |
| `terc4_encoder` | terc4_encoder.sv | ✅ hotový | LUT z HDMI spec, latency=2 |
| `hdmi_bch_ecc` | hdmi_bch_ecc.sv | ✅ overený | poly x^8+x^4+x^3+x^2+1, init=0xFF |
| `infoframe_builder` | infoframe_builder.sv | ✅ hotový | AVI/SPD/Audio, kombinačný |
| `gcp_packet_builder` | gcp_packet_builder.sv | ✅ hotový | GCP, kombinačný |
| `acr_packet_builder` | acr_packet_builder.sv | ✅ hotový | N=6144, CTS=40000, 4 subpackety, kombinačný |
| `audio_sample_packet_builder` | audio_sample_packet_builder.sv | ✅ hotový | typ 0x02, 4×L/R 16-bit, left-justified AW, P=^sample |
| `hdmi_audio_test_src` | hdmi_audio_test_src.sv | ✅ hotový | phase-acc 48kHz, 1kHz square wave, 4-sample accum |
| `hdmi_packet_arbiter` | hdmi_packet_arbiter.sv | ✅ hotový | 5 stavov, GCP→AVI→ACR→AUDIO_IF per frame, IDLE=audio samples |
| `data_island_formatter` | data_island_formatter.sv | ✅ hotový | 32 symboly, BCH/ECC, shift-reg |
| `hdmi_period_scheduler` | hdmi_period_scheduler.sv | ✅ hotový | 8-stavový FSM, VIDEO_TRIG=10, guard>=54 |
| `hdmi_channel_mux` | hdmi_channel_mux.sv | ✅ hotový | CTL hodnoty, dynamický ch0 GB |
| `tmds_phy_ddr_aligned` | tmds_phy_ddr_aligned.sv | ✅ hotový | pair_cnt, ALTDDIO_OUT, LSB-first |
| `vga_hdmi_tx` | vga_hdmi_tx.sv | ✅ hotový | ENABLE_AUDIO, ACR_N/CTS params, PIXEL_CLK_HZ |
| `hdmi_tx_core` | hdmi_tx_core.sv | ✅ hotový | PIXEL_CLK_HZ/AUDIO_SAMPLE_RATE params, plný audio path |

---

## Čo funguje (verifikované)

### Testbench simulácie (Questa FSE)
- `tb_acr_packet_builder.sv` — ALL PASSED (header, 4 subpackety, valid gating)
- `tb_audio_sample_packet_builder.sv` — ALL PASSED (header, byte split, parity)
- `tb_hdmi_period_scheduler.sv` — 4 scenáre, ALL TESTS PASSED
  - Scenár 1: No island — VIDEO_PREAMBLE=8, VIDEO_GB=2
  - Scenár 2: Min-budget island (hblank=256) — payload=32, vid_pre=8
  - Scenár 3: All period counts — all expected values matched
  - Scenár 4: Tight budget (hblank=54) — island+videopre musia sa zmestiť
- `tb_data_island_formatter.sv` — PASSED
- `tb_hdmi_bch_ecc.sv` — PASSED

### BCH/ECC matematika (Python cross-check)
- Polynóm `x^8+x^4+x^3+x^2+1`, XOR maska 0x1D, init 0xFF
- AVI header ECC: HB=[0x82,0x02,0x0D] → 0x67 ✓
- SP0 ECC → 0x51 ✓; SP1-SP3 ECC → 0xF5 ✓

### AVI InfoFrame obsah
- PB0=0x3F (checksum), PB1=0x10 (RGB), PB2=0x18 (4:3), PB3=0x08 (full range)

### CTL signálovanie (HDMI 1.3 Table 5-7)
- Video preamble: ch1=ctrl(2'b01) = 0b0010101011 (CTL2=1, CTL3=0) ✓
- Data island preamble: ch1=ctrl(2'b11) = 0b1010101011 (CTL2=1, CTL3=1) ✓

---

## Otvorené problémy — nahlásené z HW

### 1. 2-riadkový vertikálny posun (vyšetruje sa)

Prvé 2 riadky zobrazovaného obrazu sú nevalidné / celý obraz je posunutý nadol o 2 riadky.

**Hypotézy (od najpravdepodobnejšej):**
1. `video_stream_frame_aligner` potrebuje 2 riadky na sync pri prvom frame
2. Data islands na poslednej vblank línii zasahujú do prvej aktívnej línie (malo by byť vylúčené guardom >= 54)
3. `picture_gen_stream` nezačína generovať pixely dostatočne skoro

**Ďalší krok:** simulovať celý VTG → frame_aligner → vga_output_adapter → hdmi_tx_core pipeline pre prvé 3 aktívne línie a overiť, kedy sa prvý platný pixel objaví na ch\*\_o.

---

## Čo zostáva — poradie priorít

```
1. [HW] Nahrať bitstream s ENABLE_AUDIO=1, overiť audio na TV
2. [HW] Vyšetriť 2-riadkový vertikálny posun — simul. alebo osciloskop
3. [RTL] SDC multicycle path pre PHY (pix_clk → clk_pixel5x)
4. [Audio] I2S vstup — nahradiť hdmi_audio_test_src reálnym I2S prijímačom
5. [RTL] EDID/DDC I2C master + EDID parser
```

### Audio — stav (implementované 2026-05-12)

Celý audio path pre 2ch LPCM 48kHz je hotový:

```
hdmi_audio_test_src  (1 kHz square wave, phase-acc 48kHz)
  ↓ 4× (L,R) 16-bit + valid / consume
audio_sample_packet_builder  (typ 0x02, left-justified AW, BCH cez formatter)
  ↓ hb/pb
hdmi_packet_arbiter  (IDLE prezentuje audio samples; vsync_rise spustí
                      GCP → AVI → ACR → AUDIO_IF per frame)
  ↓ arb_hb / arb_pb + packet_valid_o / packet_start_i
data_island_formatter → TERC4 → hdmi_channel_mux → TMDS output
```

**Aktivácia:** `ENABLE_AUDIO=1` v `vga_hdmi_tx` parametroch (default 0).
**N/CTS:** statické N=6144, CTS=40000 (40 MHz / 48 kHz).
**Budget per hblank (256 cyklov):** GCP+AVI+ACR+AUDIO_IF = 4×44 = 176 cyklov; zostatok ~70 cyklov pre audio sample packety. Na aktívnych líniách plných 246 cyklov → 5 audio sample packetov per hblank.
**Požadované per frame:** 200 audio sample packetov; dostupné: ≫3000. ✓

---

## Historia commitov (táto séria)

| Commit | Zmena |
|---|---|
| `f2cfabb` | ~~VIDEO_TRIG 10→9~~ (chybná zmena — spôsobila 1-pixelový right shift) |
| `ca1187d` | GCP + packet arbiter (GCP→AVI per frame) |
| `7401d3b` | VTG fix: VIDEO_PREAMBLE pred prvou aktívnou líniou (last vblank line) |
| aktuálny | VIDEO_TRIG reverted 9→10 — analyticky správne pre 3-stage blank_remaining + 3-stage DE pipeline |
