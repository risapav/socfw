# HDMI implementácia — aktuálny stav (vga_test_05)

> Stav k: 2026-05-05  
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
vga_hdmi_tx  (parameter ENABLE_DATA_ISLAND=1)
  │
  ▼
hdmi_tx_core
  ├── Stage-1 input registers (de, hs, vs, hblank, vblank, blank_remaining)
  │
  ├── hdmi_period_scheduler  ──── HDMI period FSM (8 stavov)
  │     CONTROL → DATA_PREAMBLE → DATA_GB_LEAD → DATA_PAYLOAD
  │           → DATA_GB_TRAIL → CONTROL
  │     CONTROL → VIDEO_PREAMBLE → VIDEO_GB → VIDEO → CONTROL
  │
  ├── tmds_video_encoder × 3   (R, G, B; latency=2, running disparity reset)
  ├── tmds_control_encoder × 3 (ch0={vsync,hsync}, ch1=2'b00, ch2=2'b00)
  │
  ├── [gen_data_island]
  │     infoframe_builder AVI  (kombinačný, R/G/B, 4:3, full-range, VIC=0)
  │     data_island_formatter  (BCH/ECC, shift-reg serializer, 32 symboly)
  │     terc4_encoder × 3      (latency=2)
  │
  └── hdmi_channel_mux  (registrovaný, 1 cyklus latency)
        CONTROL:        ctrl symboly (ch0={vsync,hsync}, ch1/ch2=ctrl(0))
        VIDEO_PREAMBLE: ch1=ctrl(2'b01) [CTL2=1,CTL3=0]
        VIDEO_GB:       ch1/ch2=TERC4(8)=0b1011001100, ch0=ctrl
        VIDEO:          video encoder výstup
        DATA_PREAMBLE:  ch1=ctrl(2'b11) [CTL2=1,CTL3=1], ch0={vs,hs}
        DATA_GB_LEAD/TRAIL: ch1/ch2=0b0100110011, ch0=0b0100110011 (*)
        DATA_PAYLOAD:   TERC4 data island výstup
  ▼
tmds_phy_ddr_aligned  (clk_x_i = 5× pixel, pair_cnt 0..4, ALTDDIO_OUT)
  ▼
HDMI PMOD výstup (4× diff pair: B, G, R, CLK)
```

(*) ch0 guard band by mal byť TERC4({1,vsync,hsync,1}) — dynamická hodnota,
    zatiaľ aproximovaná fixnou konštantou.

---

## Moduly — stav každého

| Modul | Súbor | Stav | Poznámka |
|---|---|---|---|
| `hdmi_pkg` | hdmi_pkg.sv | ✅ hotový | 8 period stavov, typy, enums, calc_checksum |
| `tmds_video_encoder` | tmds_video_encoder.sv | ✅ hotový | DVI §3.3.3 algo, running disparity, latency=2 |
| `tmds_control_encoder` | tmds_control_encoder.sv | ✅ hotový | 4 TMDS control slová, latency=2 |
| `terc4_encoder` | terc4_encoder.sv | ✅ hotový | LUT z HDMI spec, latency=2 |
| `hdmi_bch_ecc` | hdmi_bch_ecc.sv | ✅ overený | poly x^8+x^4+x^3+x^2+1, init=0xFF, kombinačný |
| `infoframe_builder` | infoframe_builder.sv | ✅ hotový | AVI/SPD/Audio, kombinačný, checksum auto |
| `data_island_formatter` | data_island_formatter.sv | ✅ hotový | 32 symboly, 4 subpackety, BCH, shift-reg |
| `hdmi_period_scheduler` | hdmi_period_scheduler.sv | ✅ hotový | 8-stavový FSM, blank_remaining guard (>=54) |
| `hdmi_channel_mux` | hdmi_channel_mux.sv | ✅ hotový | správne CTL hodnoty pre oba preamble typy |
| `tmds_phy_ddr_aligned` | tmds_phy_ddr_aligned.sv | ✅ hotový | pair_cnt, ALTDDIO_OUT, LSB-first |
| `vga_hdmi_tx` | vga_hdmi_tx.sv | ✅ hotový | RGB565→RGB888, bridge do hdmi_tx_core + PHY |
| `hdmi_tx_core` | hdmi_tx_core.sv | ✅ hotový | ENABLE_DATA_ISLAND=1 aktívny |
| `packet_scheduler` | packet_scheduler.sv | ⚠️ osirotený | byte-stream FSM, nie je zapojený do core |

---

## Čo funguje (verifikované)

### BCH/ECC matematika (Python cross-check)
- Polynóm `x^8+x^4+x^3+x^2+1`, XOR maska 0x1D, init 0xFF
- Bit order: LSB-first per byte, byte order `pb[0]..pb[6]`
- AVI header ECC: HB=[0x82,0x02,0x0D] → 0x67 ✓
- SP0 ECC (checksum+PB1..PB6): → 0x51 ✓
- SP1-SP3 ECC (nuly): → 0xF5 ✓

### AVI InfoFrame obsah
- HB0=0x82 (typ), HB1=0x02 (verzia), HB2=0x0D (dĺžka=13)
- PB0=0x3F (checksum, verifikovaný: suma všetkých = 0x00)
- PB1=0x10 (Y1Y0=00 RGB, A0=1 AFI present)
- PB2=0x18 (M1M0=01 4:3, R=same as picture)
- PB3=0x08 (Q1Q0=10 full range)
- PB4=0x00 (VIC=0, 800×600 nie je CEA-861 mód)

### Period scheduler timing (analyticky overené)
- Video preamble trigger: `blank_remaining == 10` (2 pipeline stages od vtg)
- Preamble TMDS výstup: cykly V+5..V+12 (8 cyklov) ✓
- Guard band TMDS výstup: V+13..V+14 (2 cykly) ✓
- Prvý video pixel TMDS výstup: V+15 ✓
- Data island guard: `blank_remaining >= 54` (44 island + 10 video pre)

### CTL signálovanie (HDMI 1.3 Table 5-7)
- Video preamble: ch1=ctrl(2'b01) = 0b0010101011 (CTL2=1, CTL3=0) ✓
- Data island preamble: ch1=ctrl(2'b11) = 0b1010101011 (CTL2=1, CTL3=1) ✓

---

## Čo nie je hotové / zostáva

### Priorita 1 — overenie na HW
- **Reálny test na FPGA**: pripojiť HDMI monitor / HDMI analyzer,
  overiť či obraz zobrazuje (DVI path) a či monitor akceptuje AVI InfoFrame
- **fázové zarovnanie** pair_cnt a pixel clock: zatiaľ analyticky správne,
  treba overiť na osciloskope (pair_cnt==0 musí byť eye center)

### Priorita 2 — guard band ch0 (drobná nesprávnosť)
- `DATA_GB_LEAD/TRAIL` ch0 by mal byť `TERC4({1,vsync,hsync,1})` (dynamicky)
- Teraz je fixné `0b0100110011` — pre väčšinu monitorov pravdepodobne OK,
  ale nie je 100% spec-kompatibilné
- Oprava: v channel_mux pridať `vsync_i`/`hsync_i` vstupy a terc4 LUT

### Priorita 3 — SDC multicycle path pre PHY
- `clk_pixel → clk_pixel5x` CDC v PHY je štrukturálne bezpečné (pair_cnt),
  ale Quartus to nevie bez explicitného:
  ```
  set_multicycle_path -setup -from clk_pixel -to clk_pixel5x -num_cycles 5
  set_multicycle_path -hold  -from clk_pixel -to clk_pixel5x -num_cycles 4
  ```
- Zatiaľ `set_clock_groups -asynchronous` medzi nimi → timing sa neanalizuje

### Priorita 4 — packet_scheduler.sv
- Modul existuje ale nie je zapojený (osirotený kód)
- Pre AVI one-per-frame prístup nie je potrebný
- Pre multi-packet scenár (GCP + AVI + SPD + Audio) by bol potrebný packet arbiter

### Priorita 5 — viacero paketov za frame
- Aktuálna logika: **jeden AVI packet per vsync**, pending flag sa nastaví
  na vsync rising edge a vymaže po `packet_start`
- Neposiela GCP (General Control Packet) pred AVI — podľa HDMI spec by mal
  GCP predchádzať každý data island slot
- Viacero paketov by vyžadovalo packet arbiter + frontu

### Priorita 6 — TMDS video encoder verifikácia
- Running disparity algoritmus je implementovaný podľa DVI §3.3.3
- Nebolo robené funkčné testbench porovnanie voči referenčnému modelu
- DC balance vlastnosti neboli kvantitatívne overené

### Budúcnosť — audio (nie je začaté)
- ACR (Audio Clock Regeneration) paket: N/CTS hodnoty
- Audio Sample paketizér (IEC 60958 → HDMI pakety)
- I2S vstup alebo interný sínusový generátor pre test
- Audio InfoFrame

---

## Navrhované ďalšie úlohy (poradie)

```
1. [HW test]   Nahrať bitstream, pripojiť HDMI, overiť obraz
               → zistíme, či DVI path funguje bez ďalšej práce

2. [HW test]   Overiť AVI InfoFrame HDMI analyzerom (napr. Extron EDID manager
               alebo software HDMI capture + infoframe dump)
               → potvrdenie BCH/ECC a packet path

3. [RTL fix]   ch0 guard band: dynamický TERC4({1,vsync,hsync,1})
               → pridať vsync_i/hsync_i do hdmi_channel_mux

4. [SDC]       Pridať multicycle path constraints pre pair_cnt PHY
               → buď custom SDC snippet alebo socfw rozšírenie

5. [RTL]       GCP pred AVI: General Control Packet (header=0x03, PB0=0x00)
               odoslať jeden slot pred AVI InfoFrame každý frame

6. [Simulation] TMDS encoder testbench: ref model v Pythone / C vs SV výstup
               → kvantitatívne overenie DC balance a bit patterns

7. [Audio]     Začať ACR paket: N=6144, CTS=f(pixel_clock/audio_clock)
```

---

## Čo sa zmenilo v tejto serii commitov

| Commit | Zmena |
|---|---|
| `d3fefda` | vytvorenie vga_test_05 z vga_test_04; hdmi_tx_core rozšírený o hblank/vblank/blank_remaining |
| `...` | hdmi_bch_ecc.sv (nový), data_island_formatter.sv (nový), infoframe_builder zapojený |
| `4959199` | CTL preamble hodnoty v channel_mux (video=ctrl01, data=ctrl11) + HDMI_PERIOD_VIDEO_PREAMBLE enum |
| `0657024` | video preamble + guard band FSM stavy v period_scheduler |
| `8369627` | ENABLE_DATA_ISLAND=1, BCH overenie, timing_config dokumentácia |
