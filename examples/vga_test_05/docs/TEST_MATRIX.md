# HDMI Test Matrix

Hardware test results for `vga_test_05`. Run each configuration in order —
earlier configurations confirm basic functionality before enabling more features.

Board: AC608 (Cyclone IV), 800×600 @ 60 Hz (40 MHz pixel clock), HDMI monitor.

---

## Simulation regression (must pass before any hardware test)

Run from `sim/`:

```
make report
```

| Testbench                       | Status |
|---------------------------------|--------|
| tb_hdmi_bch_ecc                 | PASS   |
| tb_terc4_encoder                | PASS   |
| tb_data_island_formatter        | PASS   |
| tb_hdmi_period_scheduler        | PASS   |
| tb_acr_packet_builder           | PASS   |
| tb_audio_sample_packet_builder  | PASS   |
| tb_hdmi_tx_core_32x10           | PASS   |
| tb_audio_acr_only               | PASS   |
| tb_audio_if_only                | PASS   |
| tb_audio_sample_only            | PASS   |
| tb_audio_full                   | PASS   |

---

## Hardware test matrix

Parameters (`project.yaml` overrides or `soc_top.sv` generics):

- `ENABLE_DATA_ISLAND` — enables HDMI data islands (GCP + AVI every frame)
- `ENABLE_AUDIO` — enables audio packet path (ACR, Audio IF, Audio Sample)
- `ENABLE_ACR_PACKET`, `ENABLE_AUDIO_INFOFRAME`, `ENABLE_AUDIO_SAMPLE` — per-type isolation

### Baseline (DVI / no data island)

| #  | DATA | AUDIO | ACR | IF | SAMPLE | Expected                    | Result | Notes |
|----|------|-------|-----|----|--------|-----------------------------|--------|-------|
| 1  | 0    | 0     | —   | —  | —      | Stable image, no audio      |        |       |

### Data island only

| #  | DATA | AUDIO | ACR | IF | SAMPLE | Expected                    | Result | Notes |
|----|------|-------|-----|----|--------|-----------------------------|--------|-------|
| 2  | 1    | 0     | —   | —  | —      | Stable image, GCP+AVI every frame, no audio |  |  |

### Audio packets — isolation matrix

Run with `ENABLE_DATA_ISLAND=1`.

| #  | ACR | IF | SAMPLE | Expected                               | Result | Notes |
|----|-----|----|--------|----------------------------------------|--------|-------|
| 3  | 1   | 0  | 0      | Stable image; monitor acknowledges ACR |        |       |
| 4  | 0   | 1  | 0      | Stable image; audio IF present, no audio |      |       |
| 5  | 0   | 0  | 1      | Stable image or silence; monitor must NOT sleep | |  |
| 6  | 1   | 1  | 0      | Stable image; ACR + Audio IF, no samples |      |       |
| 7  | 1   | 0  | 1      | Stable image; ACR + samples            |        |       |
| 8  | 1   | 1  | 1      | Stable image + possible audio output   |        |       |

### Full audio (all enabled)

| #  | DATA | AUDIO | Expected                                 | Result | Notes |
|----|------|-------|------------------------------------------|--------|-------|
| 9  | 1    | 1     | Stable image + audio (test tone or mute) |        |       |

---

## Recording results

Fill in the **Result** column with one of:
- `PASS` — expected behavior observed
- `FAIL` — describe the failure in Notes (sleep, black screen, noise, etc.)
- `PARTIAL` — image OK but audio mismatch, or intermittent

Update this table after each hardware rebuild. Include the git commit hash in
Notes if behavior changes between builds.

---

## Known failure modes to watch for

| Symptom                 | Likely cause                            | See          |
|-------------------------|-----------------------------------------|--------------|
| Monitor goes to sleep   | Corrupted data island payload           | HDMI_PACKET_LAYOUT.md |
| Black screen, no signal | TMDS PHY misalignment after reset       | KNOWN_ISSUES.md PHY-001 |
| Image OK, no audio      | ACR N/CTS incorrect or sample rate mismatch | KNOWN_ISSUES.md PKT-001 |
| Intermittent image loss | AVI/GCP preemption at frame boundary    | KNOWN_ISSUES.md SIM-001 |
