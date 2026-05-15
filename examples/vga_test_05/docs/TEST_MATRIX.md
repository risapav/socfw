# HDMI Test Matrix

Hardware test results for `vga_test_05`. Run each configuration in order —
earlier configurations confirm basic functionality before enabling more features.

Board: QMTech EP4CE55F23C8 (Cyclone IV), 800×600 @ 60 Hz (40 MHz pixel clock), HDMI monitor.

Fill in the session header below before recording results. Monitor model matters —
one monitor may tolerate a malformed data island that causes another to sleep.

```
Git commit  : d39ff93  (last HDMI RTL commit; run git rev-parse --short HEAD for bitstream hash)
RTL hash    : d39ff93
Sim log     : sim/logs/regression_full.log  (make report PASS, 11/11 scenarios)
Date        : 2026-05-13
Monitor     : SAMSUNG LS29E790CNS/EN
```

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
| 1  | 0    | 0     | —   | —  | —      | Stable image, no audio      | PASS   |       |

### Data island only

| #  | DATA | AUDIO | ACR | IF | SAMPLE | Expected                    | Result | Notes |
|----|------|-------|-----|----|--------|-----------------------------|--------|-------|
| 2  | 1    | 0     | —   | —  | —      | Stable image, GCP+AVI every frame, no audio | FAIL | no signal immediately after enabling DATA=1/AUDIO=0; DVI baseline #1 PASS same bitstream/monitor |

### Data island debug sub-matrix

Run before proceeding to audio tests. Add `ENABLE_GCP_PACKET` / `ENABLE_AVI_PACKET`
overrides in `project.yaml` (both default to 1 when `ENABLE_DATA_ISLAND=1`).

| #  | DATA | AUDIO | GCP | AVI | Expected                          | Result | Notes |
|----|------|-------|-----|-----|-----------------------------------|--------|-------|
| 2A | 1    | 0     | 0   | 0   | Stable image; no packets inserted | PASS   | stable image; confirms DATA_ISLAND enable does not corrupt video by itself |
| 2B | 1    | 0     | 1   | 0   | Stable image; GCP only            | FAIL   | no signal; GCP-only fails while 2A (no packets) passes |
| 2C | 1    | 0     | 0   | 1   | Stable image; AVI only            |        |       |
| 2D | 1    | 0     | 1   | 1   | Stable image; GCP+AVI (= test #2) | FAIL   | no signal |

**Interpretation:**
- 2A FAIL → data-island timing/guard/preamble/mux corrupt video, not packet content
- 2A PASS, 2B FAIL → GCP packet layout or BCH/ECC error
- 2A PASS, 2C FAIL → AVI InfoFrame checksum or BCH/ECC error
- 2B PASS, 2C PASS, 2D FAIL → multi-packet sequencing or arbiter timing issue

### Data island phase isolation

`VBLANK_ONLY=1` throughout. `ENABLE_GCP_PACKET=0`, `ENABLE_AVI_PACKET=1` for all phases.

| #  | DEBUG_ISLAND_PHASES | Content                          | Result | Notes |
|----|---------------------|----------------------------------|--------|-------|
| T1 | 1                   | DATA_PREAMBLE only               | PASS   | stable image; preamble alone does not disrupt monitor |
| T2 | 2                   | preamble + data guard bands      | FAIL   | monitor rejects malformed island (0 payload symbols); guard band Ch0 nibble also fixed ({1,VSYNC,HSYNC,1}→{1,1,VSYNC,HSYNC}) |
| T3 | 3                   | preamble + guard + 1 payload sym | SKIP   | Samsung rejects malformed island structure; T2 fails same way |
| T0 | 0                   | full 32-symbol payload           | FAIL   | parity missing vsync/hsync (CTL0/CTL1); fixed; re-test pending |

**Interpretation:**
- T1 PASS, T2 FAIL → fault is in DATA_GB_LEAD / DATA_GB_TRAIL symbols or channel assignment
- T2 PASS, T3 FAIL → fault is in TERC4 encoding, formatter/mux pipeline alignment, or first payload symbol
- T3 PASS, T0 FAIL → fault is in payload length, 32-symbol sequencing, ECC, or trailing boundary
- NOTE: Samsung LS29E790CNS rejects malformed island structure — T2/T3 not viable on this monitor.
  Guard band nibble fixed per spec. Proceeding to T0 (full 32-symbol island).

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
