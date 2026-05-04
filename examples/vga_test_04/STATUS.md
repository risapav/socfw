# vga_test_04 — Stav implementácie

## Architektúra

```
picture_gen_stream  (AXI-S source, continuous mode)
        │
        │ AXI-Stream RGB565 + SOF/EOL/EOF
        ▼
video_stream_fifo_sync  (synchronous LUT FIFO, DEPTH=1600)
        │
        │ AXI-Stream RGB565 + SOF/EOL/EOF
        ▼
video_stream_frame_aligner  (FSM: SOF lock + frame timing alignment)
        │ pixel_req / frame_start / de / last_active_x / last_active_pixel
        │ ◄── video_timing_generator (800×600 @ 60 Hz, 40 MHz pixel clock)
        │
        │ pixel_o (RGB565, registered, 1-cycle latency)
        ▼
vga_output_adapter            →  board VGA pins (R5/G6/B5 + HS/VS)
        │ active_video_o
        ▼
vga_hdmi_tx
  └── hdmi_tx_core (ENABLE_DATA_ISLAND=0, DVI-compatible)
        ├── hdmi_period_scheduler  (CONTROL ↔ VIDEO FSM)
        ├── tmds_video_encoder ×3  (pipelined, running disparity, 2-cycle latency)
        ├── tmds_control_encoder ×3
        └── hdmi_channel_mux
  └── tmds_phy_ddr_aligned         →  board HDMI PMOD pins (4 TMDS pairs)
        └── ALTDDIO_OUT ×4 (pair_cnt 0..4, word-aligned, LSB-first)
```

## Čo je funkčné (DVI-compatible cesta)

- **video_timing_generator**: generuje DE/HS/VS + look-ahead `pixel_req_o` (1 takt pred DE), `frame_start_o`, `hblank_o`, `vblank_o`, `last_active_x_o`, `last_active_pixel_o`
- **video_stream_frame_aligner**: FSM so 4 stavmi (SEARCH_SOF → WAIT_FRAME_START → STREAM_FRAME → DROP_BROKEN_FRAME); SOF pixel zostáva vo FIFO (nespotrebúva sa predčasne); `pixel_take` používa `state_next` pre správne správanie pri simultánnom `frame_start+pixel_req`; `underflow_sticky_o` flag
- **vga_output_adapter**: jednoduchý registrovaný VGA output driver s `active_video_o`
- **tmds_video_encoder**: pipelined TMDS encoding (DVI 1.0 §3.3.3); opravená DC-balance Stage 2 (`invert = ~q_m[8]` pri `cnt==0 || neutral`)
- **tmds_phy_ddr_aligned**: word-aligned DDR serializer s `pair_cnt` (0..4) v `clk_x_i` doméne; nahrádza starý `generic_serializer` s nespoľahlivým toggle-CDC
- **packet_scheduler**: skip logika pre zakázané pakety (len_spd==0 alebo len_audio==0 preskočí celý header+payload)

## Opravené problémy (navrhy_01 až navrhy_03)

| Problém | Oprava |
|---|---|
| Monolitický VGA modul | Rozdelený pipeline: timing_gen + frame_aligner + vga_adapter |
| CDC toggle serializer (generic_serializer) | Nahradený tmds_phy_ddr_aligned s pair_cnt |
| SOF pixel bol spotrebúvaný | ST_SEARCH_SOF: s_axis_ready_o=0 keď SOF vidí |
| Simultánny frame_start+pixel_req ignorovaný | ST_WAIT_FRAME_START: s_axis_ready_o=pixel_req_i; pixel_take používa state_next |
| TMDS DC-balance: invert pri cnt==0 bol nesprávny | Merged: `if (rd==0 || neutral) invert=~q_m[8]` |
| packet_scheduler neposkočil disabled pakety | Pridaná skip logika pre len==0 |
| hdmi_tx_top (starý modul) | Nahradený hdmi_tx_core + tmds_phy_ddr_aligned |

## Zostávajúce problémy (identifikované v navrhy_04)

| Problém | Závažnosť | Poznámka |
|---|---|---|
| `pix_clk_i` v tmds_phy_ddr_aligned je nepoužívaný | Nízka | Quartus hlási unused port |
| `vblank = vsync_r` je nesprávne | Stredná | Pre DVI-only nevadí; pre HDMI data islands je to chyba |
| EOL/EOF check nie je implementovaný | Stredná | Porty `last_active_x_i`/`last_active_pixel_i` sú zapojené, ale nekontrolujú sa |
| hdmi_period_scheduler nemá blank_remaining guard | Stredná | Môže začať data island príliš neskoro v blankingu |
| data_island_formatter chýba | Vysoká | Pre plné HDMI s InfoFrames |
| BCH/ECC generátory chýbajú | Vysoká | Pre plné HDMI pakety |

## Čo chýba do plného HDMI (navrhy_05 roadmapa)

```
Fáza 3: BCH/ECC header (24→8 bit) + subpacket (56→8 bit)
Fáza 4: data_island_formatter (presný channel mapping 32 symbolov)
Fáza 5: AVI InfoFrame cez data island
Fáza 6: GCP packet
Fáza 7: Audio InfoFrame
Fáza 8: ACR N/CTS generator
Fáza 9: audio_sample_packetizer (2ch LPCM 48 kHz)
Fáza 10: I2S vstup + async FIFO
Fáza 11: EDID/DDC čítanie
```

## Quartus stav (posledný build)

- **0 errors, 16 warnings** (benign: unused ports, missing constraints pre multi-cycle paths)
- Target device: Cyclone IV E EP4CE55F23C8
- Pixel clock: 40 MHz (800×600 @ 60 Hz VESA)
- HDMI clock: 200 MHz (5× pixel, DDR serializer)
- ENABLE_DATA_ISLAND: 0 (DVI-compatible)
