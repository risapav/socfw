# Navrhy 43 — Root cause: Data Island Guard Band Bug C

## Výsledky HW testov

```
2B: GCP only (VBLANK_ONLY=1)  FAIL — screen blank
2C: AVI only (VBLANK_ONLY=1)  FAIL — screen blank
```

Oba testy zlyháva rovnakým spôsobom napriek rôznym typom paketov.
Eliminuje hypotézu "Samsung vyžaduje AVI InfoFrame" — problém je štrukturálny.

---

## Root cause: Bug C v hdmi_channel_mux.sv

### Symptóm

Samsung dostáva na Ch1 a Ch2 DATA_GUARD_LEAD/TRAIL neplatné TERC4 symboly
→ detekuje malformovaný data island → obraz zhasne.

### Príčina

`GB_DATA_N = 10'b0100110011` je Video Guard Band Ch1 symbol (komplement GB_VIDEO).
Bol omylom použitý aj pre Data Island Guard Band:

```systemverilog
// BUG C — pred opravou:
HDMI_PERIOD_DATA_GB_LEAD,
HDMI_PERIOD_DATA_GB_TRAIL: begin
    ch2_next = GB_DATA_N;   // 0100110011 — NOT a valid TERC4 symbol
    ch1_next = GB_DATA_N;   // 0100110011 — NOT a valid TERC4 symbol
    ch0_next = gb_data_ch0; // correct
end
```

### HDMI 1.3 spec Table 5-8 — správne hodnoty

| Ch  | Required           | Value      |
|-----|--------------------|------------|
| Ch2 | TERC4(4'hB)        | 1011000110 |
| Ch1 | TERC4(4'h4)        | 0101110001 |
| Ch0 | TERC4({1,1,VS,HS}) | varies     |

### Oprava

```systemverilog
localparam tmds_word_t GB_DATA_CH1 = 10'b0101110001;  // TERC4(4'h4)
localparam tmds_word_t GB_DATA_CH2 = 10'b1011000110;  // TERC4(4'hB)

HDMI_PERIOD_DATA_GB_LEAD,
HDMI_PERIOD_DATA_GB_TRAIL: begin
    ch2_next = GB_DATA_CH2;
    ch1_next = GB_DATA_CH1;
    ch0_next = gb_data_ch0;
end
```

---

## Prečo to sim nezachytil

`tb_hdmi_tmds_decode.sv` zachytával iba `HDMI_PERIOD_DATA_PAYLOAD` symboly.
Guard band periódy neboli nikdy overené.

`tb_hdmi_tx_core_32x10.sv` mal guard band check, ale s OLD hodnotami
(`GB_DATA_N` pre oba kanály) — asertoval nesprávne správanie ako správne.

### Opravené sim pokrytie

1. `tb_hdmi_tmds_decode.sv` — pridaný check počas `DATA_GB_LEAD` a `DATA_GB_TRAIL`:
   - ch2 must == TERC4(4'hB) = 1011000110
   - ch1 must == TERC4(4'h4) = 0101110001
   - ch0 must be one of TERC4({1,1,x,y})
   - cnt_gb counted and checked > 0

2. `tb_hdmi_tx_core_32x10.sv` — konštanty opravené na `GB_DATA_CH1`/`GB_DATA_CH2`.

Regression: 12/12 PASS po oprave.

---

## Kontext: história bugov v channel mux

| Bug | Komponent          | Chyba                             | Efekt                               |
|-----|--------------------|-----------------------------------|-------------------------------------|
| A   | DATA_PREAMBLE      | Ch1=ctrl(11), Ch2=ctrl(00)        | Monitor nerozoznal preamble         |
| B   | VIDEO_GB           | Ch0=ctrl, Ch1=GB_VIDEO            | Spec non-compliant (video tolerant) |
| C   | DATA_GB_LEAD/TRAIL | Ch1=Ch2=GB_DATA_N (neplatný TERC4)| Monitor drops island, screen blank  |

Všetky tri bugy v `hdmi_channel_mux.sv`.

---

## Ďalší postup

Aktuálny `project.yaml`: 2B re-test (GCP only, VBLANK_ONLY=1, DEBUG_ISLAND_PHASES=0).

```
2B PASS → 2C (AVI only)
2C PASS → 2D (GCP+AVI)
2D PASS → audio testy (test #3 ACR only)
```

Ak 2B stále FAIL: skontroluj ch0 guard band timing (VSYNC/HSYNC alignment do muxu).
