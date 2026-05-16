# HDMI implementácia — aktuálny stav (vga_test_05)

> Stav k: 2026-05-16
> Quartus: 0 errors, 16 warnings (len historické truncation warnings)
> Posledný HW test: 2C (AVI only) — FAIL
> Simulácia: 14/14 PASS (`make report` v sim/)

---

## Architektúra — čo je implementované

### Vrstvy od pixelov po TMDS výstup

```
video_timing_generator
  |  de, hsync, vsync, hblank, vblank
  |  blank_remaining[15:0], frame_start
  |  last_active_x_req, last_active_pixel_req
  v
vga_output_adapter
  |  active_video_o, vga_r/g/b_o, vga_hs/vs_o  (1 register stage)
  v
vga_hdmi_tx  (parameter ENABLE_DATA_ISLAND=1)
  |  RGB565 -> RGB888 (kombinacne)
  |  vga_de_i = active_video_o (priamy drot, nie cez board pin)
  |  vga_r/g/b/hs/vs_i = VGA_R/G/B/HS/VS (top-level output wire)
  v
hdmi_tx_core
  +-- Stage-1 input registers (de, hs, vs, hblank, vblank, blank_remaining)
  +-- Extra align reg: blank_remaining_rr, hblank_rr  (3-stage blank_remaining pipeline)
  |
  +-- hdmi_period_scheduler  ---- HDMI period FSM (8 stavov)
  |     CONTROL -> VIDEO_PREAMBLE -> VIDEO_GB -> VIDEO -> CONTROL
  |     CONTROL -> DATA_PREAMBLE -> DATA_GB_LEAD -> DATA_PAYLOAD
  |            -> DATA_GB_TRAIL -> CONTROL
  |     VIDEO_TRIG = 10  (blank_remaining_rr <= 10 spusta VIDEO_PREAMBLE)
  |     DVI path (ENABLE_DATA_ISLAND=0): period = de_r ? VIDEO : CONTROL
  |
  +-- tmds_video_encoder x 3   (R, G, B; latency=2, running disparity)
  +-- tmds_control_encoder x 3 (ch0={vsync,hsync}, ch1=2'b00, ch2=2'b00)
  |
  +-- [gen_data_island]  (iba ak ENABLE_DATA_ISLAND=1)
  |     gcp_packet_builder      (GCP -- staticke, kombinacne)
  |     infoframe_builder AVI   (kombinacny, R/G/B, 4:3, full-range, VIC=0)
  |     hdmi_packet_arbiter     (GCP->AVI->ACR->AUDIO_IF per frame, IDLE=audio)
  |     data_island_formatter   (BCH/ECC, shift-reg, 32 symboly)
  |     terc4_encoder x 3       (latency=2)
  |
  +-- hdmi_channel_mux  (registrovany, 1 cyklus latency)
        CONTROL:        ctrl symboly (ch0={vsync,hsync}, ch1/ch2=ctrl(0))
        VIDEO_PREAMBLE: ch1=ctrl(2'b01), ch2=ctrl(2'b00), ch0=ctrl({vs,hs})
        VIDEO_GB:       ch0=ch2=TERC4(4'h8)=1011001100, ch1=0100110011
        VIDEO:          video encoder vystup
        DATA_PREAMBLE:  ch1=ch2=ctrl(2'b01), ch0=ctrl({vs,hs})
        DATA_GB_LEAD/TRAIL: ch1=TERC4(4'h4)=0101110001, ch2=TERC4(4'hB)=1011000110,
                             ch0=TERC4({1,1,vs,hs})
        DATA_PAYLOAD:   TERC4 data island vystup
  v
tmds_phy_ddr_aligned  (clk_x_i = 5x pixel, pair_cnt 0..4, ALTDDIO_OUT)
  v
HDMI PMOD vystup (4x diff pair: B, G, R, CLK)
```

---

## Pipeline zarovnanie — VIDEO_TRIG = 10

VIDEO_TRIG = 10 je analyticky overena hodnota, **simulacne potvrdena** testom `tb_dvi_vs_2a`.

**Pipeline (trigger posedge T, blank_remaining_rr = 10):**

| Signal | Latencia od T |
|--------|--------------|
| de_comb = 1 | T+7 (blank_remaining 3 fazy) |
| de_o (VTG reg) | T+8 |
| active_video_o (vgaout0) | T+9 |
| de_r (hdmi stage-1) | T+10 |
| enc stage-1 | T+11 |
| TMDS(pixel[0]) na tmds_o | T+12 |
| ch*_o pri channel_mux | **T+13** |

**Period FSM:**

| Stav | Cas pri ch*_o |
|------|---------------|
| VIDEO_PREAMBLE (8 cy) | T+1 ... T+8 |
| VIDEO_GB (2 cy) | T+9, T+10 |
| VIDEO | T+11 na period_o → T+12 period_d1 → **T+13** ch*_o |

Zarovnanie: obe cesty pridu na ch*_o v rovnakom cykle T+13. **VIDEO_TRIG = 10 je spravne.** ✓

**Simulacne overenie (tb_dvi_vs_2a, 2026-05-16):**
- DVI vs 2A: VIDEO onset cyklus zhodny (diff=0), 1297 VIDEO cyklov bit-identickych
- Zaver: pipeline alignment je SPRAVNY, zelena ciara nie je RTL bug

---

## Moduly — stav kazdeho

| Modul | Subor | Stav | Poznamka |
|---|---|---|---|
| `hdmi_pkg` | hdmi_pkg.sv | OK | 8 period stavov, typy, enums |
| `tmds_video_encoder` | tmds_video_encoder.sv | OK | DVI §3.3.3, running disparity, latency=2 |
| `tmds_control_encoder` | tmds_control_encoder.sv | OK | 4 TMDS control slova, latency=2 |
| `terc4_encoder` | terc4_encoder.sv | OK | LUT z HDMI spec, latency=2 |
| `hdmi_bch_ecc` | hdmi_bch_ecc.sv | OK | poly x^8+x^4+x^3+x^2+1, init=0xFF |
| `infoframe_builder` | infoframe_builder.sv | OK | AVI/SPD/Audio, kombinacny |
| `gcp_packet_builder` | gcp_packet_builder.sv | OK | GCP, kombinacny |
| `acr_packet_builder` | acr_packet_builder.sv | OK | N=6144, CTS=40000, 4 subpackety |
| `audio_sample_packet_builder` | audio_sample_packet_builder.sv | OK | typ 0x02, 4xL/R 16-bit |
| `hdmi_audio_test_src` | hdmi_audio_test_src.sv | OK | phase-acc 48kHz, 1kHz square wave |
| `hdmi_packet_arbiter` | hdmi_packet_arbiter.sv | OK | 5 stavov, GCP->AVI->ACR->AUDIO_IF per frame |
| `data_island_formatter` | data_island_formatter.sv | OK | 32 symboly, BCH/ECC, shift-reg |
| `hdmi_period_scheduler` | hdmi_period_scheduler.sv | OK | 8-stavovy FSM, VIDEO_TRIG=10, guard>=54 |
| `hdmi_channel_mux` | hdmi_channel_mux.sv | OK | CTL hodnoty, dynamicky ch0 GB |
| `tmds_phy_ddr_aligned` | tmds_phy_ddr_aligned.sv | OK | pair_cnt, ALTDDIO_OUT, LSB-first |
| `vga_hdmi_tx` | vga_hdmi_tx.sv | OK | ENABLE_AUDIO, ACR_N/CTS params |
| `hdmi_tx_core` | hdmi_tx_core.sv | OK | plny audio path, GCP_FRAME_PERIOD |

---

## Simulacia — stav (14/14 PASS)

```
make report   # spusti vsetky testy, zapisuje logs/regression_full.log
```

| Testbench | Vysledok | Co overuje |
|---|---|---|
| tb_hdmi_bch_ecc | PASS | BCH/ECC polynomial, init, LSB-first |
| tb_terc4_encoder | PASS | TERC4 LUT vsetkych 16 nibbles |
| tb_data_island_formatter | PASS | 32-symbol serializer, BCH insert |
| tb_hdmi_period_scheduler | PASS | 4 scenare, period lengths, VIDEO_TRIG |
| tb_acr_packet_builder | PASS | ACR header, 4 subpackety, N/CTS |
| tb_audio_sample_packet_builder | PASS | header, byte split, parity |
| tb_hdmi_tx_core_32x10 | PASS | period/de alignment, packet content |
| tb_di_2a | PASS | ENABLE_DATA_ISLAND=1, GCP=0, AVI=0: ziadne data periods |
| tb_di_2b | PASS | GCP=1, AVI=0: 4 GCP packety, BCH spravny |
| tb_di_2c | PASS | GCP=0, AVI=1: 4 AVI packety, BCH spravny |
| tb_di_2d | PASS | GCP=1, AVI=1: 4 GCP + 3 AVI packety |
| tb_hdmi_tmds_decode | PASS | TERC4 decode GCP/AVI z realneho TMDS vystupu |
| tb_tmds_phy_loopback | PASS | PHY serializer, 32/32 symbolov, LSB-first, DDR |
| tb_dvi_vs_2a | PASS | DVI vs 2A: rovnaky VIDEO onset, 1297 bitovo identickych cyklov |
| tb_audio_acr_only | PASS | audio scenario: ACR only |
| tb_audio_if_only | PASS | audio scenario: Audio IF only |
| tb_audio_sample_only | PASS | audio scenario: samples only |
| tb_audio_full | PASS | audio scenario: plna konfiguracia |

---

## HW test matica — kompletny stav

Monitor: Samsung LS29E790CNS/EN, 800x600 @ 60 Hz VESA (40 MHz pixel clock)

| Test | Konfiguracia | Vysledok | Symptom / Poznamka |
|------|-------------|----------|--------------------|
| T1 — DVI baseline | DATA=0, AUDIO=0 | **PASS** | Stabilny obraz, ziadne artefakty |
| T2 — DATA_ISLAND infra | DATA=1, GCP=0, AVI=0 (=2A) | **PARTIAL** | Obraz viditelny ale posunuty doprava, zelena ciara vlavo; vid. nizsie |
| T3 — GCP only | DATA=1, GCP=1, AVI=0 (=2B) | **FAIL** | Cierny obraz / ziadny signal; Samsung vyzaduje AVI InfoFrame |
| T4 — AVI only | DATA=1, GCP=0, AVI=1 (=2C) | **FAIL** | Samsung stale neakceptuje; vid. nizsie |
| DEBUG_ISLAND_PHASES=1 | preamble only | **PASS** | Preamble sama obraz nekazi |
| DEBUG_ISLAND_PHASES=2 | preamble + guard bands | FAIL | Samsung odmieta neuplny island |

### 2A (DATA_ISLAND=1, bez packetov) — detailna analyza

**Symptom:** Obraz viditelny ale posunuty 10 pixelov doprava, zelena ciara na lavom okraji.

**HW diagnosticke pokusy (navrhy_49, vysledky v navrhy_50):**
- Test A: `hblank_r` / `blank_remaining_r` namiesto `_rr` — nepomohlo
- Test B: `period` namiesto `period_d1` pre mux — nepomohlo
- Test C: `period_d2` (extra delay) — nepomohlo
- Zmena zdroja de / hs / vs — nepomohla
- Zmeny blank_remaining delay ovplyvnili posun ale neopravili ho

**Simulacne overenie (tb_dvi_vs_2a, PASS):**
- VIDEO onset: DVI = 2A (diff = 0 cyklov)
- Pixel obsah: 1297 VIDEO cyklov bit-identickych
- **Zaver: pipeline alignment je SPRAVNY. Posun nie je RTL bug.**

**Najpravdepodobnejsia pricina (navrhy_50):**
Samsung LS29E790CNS nerozpoznava HDMI VIDEO_PREAMBLE/VIDEO_GB symboly v 800x600
bez platnej InfoFrame. Bez AVI ostava v DVI-kompatibilnom mode a interpetuje 10-cyklovy
preamble+guard ako pixel data (shift o 10 pixelov doprava, VIDEO_GB farba = zelena ciara).

### 2C (AVI only) — analyza

**Symptom:** FAIL — Samsung stale neakceptuje signal.

**Mozne priciny:**
1. Samsung LS29E790CNS odmieta 800x600 v HDMI mode (nestandartny non-CEA timing)
2. AVI InfoFrame obsah je spravny podla BCH/sim, ale Samsung ho z neakeho dovodu ignoruje
3. HDMI preamble timing je spravny, ale Samsung ma problematicky HDMI receiver pre DMT timings
4. Nejaky dalsie neopraveny RTL bug mimo pouzivanych testbenchov

---

## Opravene bugy (vsetky v hdmi_channel_mux.sv)

| Bug | Problem | Oprava |
|-----|---------|--------|
| Bug A — DATA_PREAMBLE | ch1=ctrl(2'b11), ch2=ctrl(2'b00) — zly CTL2/CTL3 | ch1=ch2=ctrl(2'b01) = PRE_VIDEO_CH1 |
| Bug B — VIDEO_GB | ch0=ctrl (zive), ch1=GB_VIDEO | ch0=ch2=GB_VIDEO=TERC4(4'h8), ch1=GB_DATA_N |
| Bug C — DATA_GB | ch1=ch2=GB_DATA_N (0100110011) — zly symbol | ch1=TERC4(4'h4)=0101110001, ch2=TERC4(4'hB)=1011000110 |

---

## Navrhnuty dalsi postup (navrhy_50)

### Hypoteza navrhy_50

Kedze Test A/B/C nepomohli, expert odmieta hypotezu pipeline mismatch. Nova hypoteza:

> Problem je v samotnom HDMI video period modeli — VIDEO_PREAMBLE + VIDEO_GB
> symboly pred aktivnym videom matia Samsung ked nie su sprevadzane platnym HDMI
> InfoFrame. Samsung ich interpretuje ako pixel data.

### Navrhovany test: DEBUG_DVI_VIDEO_WHEN_NO_PACKETS

Pridat do `hdmi_period_scheduler.sv` (alebo `hdmi_tx_core.sv`) parameter:

```systemverilog
parameter bit DEBUG_DVI_VIDEO_WHEN_NO_PACKETS = 0
```

Ked su VSETKY packety vypnute (GCP=0, AVI=0, ACR=0, audio=0) a tento parameter=1,
scheduler pouzije DVI fast path aj v HDMI mode:

```
de=1  -> VIDEO   (bez VIDEO_PREAMBLE / VIDEO_GB)
de=0  -> CONTROL
```

**Ocakavanie:**
- Ak 2A obraz bude OK (bez posunu): potvrdeny root cause je VIDEO_PREAMBLE/VIDEO_GB timing
- Ak 2A ostane posunuty: problem je inde v ENABLE_DATA_ISLAND vetve

### Varianty V1-V4 pre dalsi debug VIDEO boundary

Po potvrdeni DEBUG_DVI_VIDEO_WHEN_NO_PACKETS:

| Variant | Preamble | VIDEO_GB | Ocakavanie |
|---------|---------|---------|-----------|
| V1 | nie | nie | PASS — DVI-like |
| V2 | ano | nie | ak FAIL: preamble je problem |
| V3 | nie | ano | ak FAIL: VIDEO_GB je problem |
| V4 | ano | ano | standard HDMI (aktualny stav) |

### Alternativna hypoteza: 800x600 nie je CEA timing

Samsung LS29E790CNS moze odmietal HDMI data islands pre 800x600 VESA (DMT timing)
ktory nie je v CEA-861 zozname. Riesenie: skusit monitor so standardnym HDMI
timingom (720p, 1080p) alebo iny monitor.

---

## Aktualna konfiguracia project.yaml

```yaml
ENABLE_DATA_ISLAND: 1
ENABLE_AUDIO: 0
ENABLE_GCP_PACKET: 0
ENABLE_AVI_PACKET: 1   # 2C test (AVI only) -- posledny HW test, FAIL
ENABLE_ACR_PACKET: 0
ENABLE_AUDIO_INFOFRAME: 0
ENABLE_AUDIO_SAMPLE: 0
GCP_FRAME_PERIOD: 1
VBLANK_ONLY: 1
DEBUG_ISLAND_PHASES: 0
```

---

## Co zostava — poradie priorit

```
PRIORITA 1 [RTL] Implementovat DEBUG_DVI_VIDEO_WHEN_NO_PACKETS
   Pridat parameter do hdmi_period_scheduler.sv
   Testovat 2A na HW: ak opraví posun -> potvrdeny root cause je VIDEO_PREAMBLE/GB
   Ak nepomôze -> problemom je iny aspekt ENABLE_DATA_ISLAND vetvy

PRIORITA 2 [HW] Ak DEBUG test prejde: rozbit na V1-V4 (vid. vyssie)
   Identifikovat presne ci VIDEO_PREAMBLE alebo VIDEO_GB je vinnik

PRIORITA 3 [HW] Ak 800x600 HDMI je fundamentalne problem Samsungu:
   Skusat iny monitor (non-Samsung)
   Alebo overit ze 2D (GCP+AVI) funguje -- Samsung moze potrebovat oba packety

PRIORITA 4 [HW] Po vyrieseni 2A:
   2D (GCP+AVI) -- standardna konfiguracia
   ENABLE_AUDIO=1 -- overit audio

PRIORITA 5 [RTL] SDC multicycle path pre PHY (pix_clk -> clk_pixel5x)
PRIORITA 6 [Audio] I2S vstup -- nahradit hdmi_audio_test_src realnym I2S
PRIORITA 7 [RTL] EDID/DDC I2C master + EDID parser
```

---

## Audio path — stav (implementovany, netestovany na HW)

Cely audio path pre 2ch LPCM 48kHz je hotovy, simulacne overeny:

```
hdmi_audio_test_src  (1 kHz square wave, phase-acc 48kHz)
  | 4x (L,R) 16-bit + valid / consume
audio_sample_packet_builder  (typ 0x02, left-justified AW, BCH)
  | hb/pb
hdmi_packet_arbiter  (GCP -> AVI -> ACR -> AUDIO_IF per frame)
  | arb_hb / arb_pb + packet_valid_o / packet_start_i
data_island_formatter -> TERC4 -> hdmi_channel_mux -> TMDS output
```

Aktivacia: `ENABLE_AUDIO=1` v `vga_hdmi_tx` parametroch.
N/CTS: staticke N=6144, CTS=40000 (40 MHz / 48 kHz).

---

## BCH/ECC — overene hodnoty

Polynomial: x^8+x^4+x^3+x^2+1, XOR maska 0x1D, init 0xFF, LSB-first.

| Packet | HB[0..2] | BCH_hdr | BCH_sp0 |
|--------|---------|---------|---------|
| GCP (all-zero) | 00 00 00 | 0x0E | 0xF5 |
| AVI InfoFrame | 82 02 0D | 0x67 | 0x51 |

AVI payload: PB0=0x3F (checksum), PB1=0x10 (RGB), PB2=0x18 (4:3), PB3=0x08 (full range).

---

## Historia oprav v tejto serii

| Commit | Zmena |
|--------|-------|
| `7b992a3` | VIDEO_TRIG revert 9->10 (f2cfabb bol chybny -- sposoboval 1px right shift) |
| `f2cfabb` | ~~VIDEO_TRIG 10->9~~ (chybna zmena) |
| `ca1187d` | GCP + packet arbiter (GCP->AVI per frame) |
| `7401d3b` | VTG fix: VIDEO_PREAMBLE pred prvou aktivnou liniou (last vblank line) |
| `a5bdd95` | sim: tb_hdmi_tmds_decode (TERC4 black-box decode) |
| `a6202a5` | Bug A fix (DATA_PREAMBLE CTL) + Bug B fix (VIDEO_GB swap) |
| `11d66e8` | data island parity: pridane vsync/hsync do XOR |
| `5374655` | Bug C fix (DATA_GB guard band TERC4 hodnoty) |
| nedokumentovane | tb_tmds_phy_loopback + ddio_out_sim.sv (PHY loopback sim) |
| nedokumentovane | tb_dvi_vs_2a (DVI vs 2A pipeline alignment comparison) |
