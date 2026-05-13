Áno. Pri tomto type HDMI jadra by som výsledky testov fixoval v troch vrstvách:

```text
1. test log / report
2. automatický regression test
3. komentár alebo dokumentácia priamo pri module
```

Cieľ je, aby si o mesiac vedel povedať:

```text
toto správanie je zámerné,
tento timing offset je overený,
tento packet layout má golden test,
táto korekcia opravovala konkrétny bug.
```

---

# 1. Zaveď adresár pre výsledky testov

Odporúčam štruktúru:

```text
sim/
  Makefile
  tb_*.sv
  logs/
    2026-05-13/
      tb_hdmi_tx_core_32x10.log
      tb_data_island_formatter.log
      regression_summary.txt
  waves/
    failing/
    passing/
  golden/
    acr_packet_48k_40mhz.txt
    avi_infoframe_rgb_800x600.txt
    data_island_avi_symbols.txt
  reports/
    TEST_RESULTS.md
```

Do git-u by som ukladal najmä:

```text
sim/golden/*
sim/reports/TEST_RESULTS.md
sim/*.sv
```

Logy z každého behu môžeš ukladať podľa potreby. Ak sú veľké, nedávaj ich všetky do git-u. Ale „referenčné passing logy“ pre dôležité míľniky sa oplatí uložiť.

---

# 2. Pridaj regression target do Makefile

V `sim/Makefile` by som mal minimálne:

```makefile
.PHONY: all regression clean report

TESTS := \
	bch_ecc \
	data_island \
	scheduler \
	acr_packet \
	audio_sample_pkt \
	tx_core_32x10

all: regression

regression: $(TESTS)
	@echo "======================================"
	@echo " HDMI SIM REGRESSION PASSED"
	@echo " Tests: $(TESTS)"
	@echo "======================================"

report:
	@mkdir -p logs
	@echo "HDMI regression run" > logs/regression_summary.txt
	@date >> logs/regression_summary.txt
	@$(MAKE) regression 2>&1 | tee logs/regression_full.log
```

Ešte lepšie je, aby každý test zapisoval vlastný log:

```makefile
LOGDIR ?= logs

$(LOGDIR):
	mkdir -p $(LOGDIR)

bch_ecc: $(LOGDIR)
	vlib work
	vlog $(COMMON) tb_hdmi_bch_ecc.sv
	vsim -c tb_hdmi_bch_ecc -do "run -all; quit" | tee $(LOGDIR)/tb_hdmi_bch_ecc.log
	@grep -q "PASS" $(LOGDIR)/tb_hdmi_bch_ecc.log
```

Pointa: test má skončiť chybou, ak log neobsahuje PASS alebo obsahuje ERROR.

---

# 3. Štandardizuj PASS/FAIL výstup v každom testbenchi

Každý testbench by mal mať rovnaký koniec:

```systemverilog
initial begin
  errors = 0;

  run_test();

  if (errors == 0) begin
    $display("=================================================");
    $display("PASS: %m");
    $display("=================================================");
  end else begin
    $display("=================================================");
    $display("FAIL: %m errors=%0d", errors);
    $display("=================================================");
    $fatal(1);
  end

  $finish;
end
```

A všetky kontroly nech používajú jeden helper:

```systemverilog
int errors;

task automatic check_eq32(
  input string name,
  input logic [31:0] got,
  input logic [31:0] exp
);
  if (got !== exp) begin
    errors++;
    $error("%s: got=0x%08x exp=0x%08x", name, got, exp);
  end
endtask
```

Pre 10-bit TMDS:

```systemverilog
task automatic check_tmds(
  input string name,
  input logic [9:0] got,
  input logic [9:0] exp
);
  if (got !== exp) begin
    errors++;
    $error("%s: got=%010b exp=%010b", name, got, exp);
  end
endtask
```

Takto máš konzistentný výstup v logoch.

---

# 4. Zafixuj „golden vectors“

Pre HDMI je veľmi dôležité mať uložené očakávané hodnoty.

Napríklad:

```text
sim/golden/
  terc4_lut.txt
  bch_header_vectors.txt
  bch_subpacket_vectors.txt
  avi_rgb_800x600_payload.txt
  acr_40mhz_48khz_payload.txt
  audio_sample_packet_16bit_stereo.txt
```

Príklad `terc4_lut.txt`:

```text
# nibble expected_terc4
0 1010011100
1 1001100011
2 1011100100
3 1011100010
4 0101110001
5 0100011110
6 0110001110
7 0100111100
8 1011001100
9 0100111001
A 0110011100
B 1011000110
C 1010001110
D 1001110001
E 0101100011
F 1011000011
```

Tieto golden súbory sú dobré preto, že presne hovoria:

```text
toto nie je náhodný výstup simulácie,
toto je očakávaná špecifikovaná hodnota.
```

---

# 5. Do každého modulu daj „behavior contract“

Do hlavičky modulu by som nedával dlhý denník zmien, ale krátky kontrakt správania.

Napríklad pre `terc4_encoder.sv`:

```systemverilog
/**
 * @file terc4_encoder.sv
 * @brief HDMI TERC4 encoder for data island symbols.
 *
 * Behavior contract:
 * - Maps 4-bit HDMI data island nibble to 10-bit TERC4 symbol.
 * - Output latency is exactly 2 pixel-clock cycles.
 * - This latency intentionally matches tmds_video_encoder and
 *   tmds_control_encoder so that hdmi_channel_mux can select between
 *   video/control/data paths using one common delayed period signal.
 *
 * Verified by:
 * - tb_terc4_encoder.sv
 * - tb_hdmi_tx_core_32x10.sv data island payload alignment checks
 *
 * Important:
 * - Do not reduce latency to 1 cycle unless hdmi_tx_core pipeline is updated.
 */
```

Toto je veľmi cenné. Keď sa neskôr niekto pozrie na encoder, okamžite pochopí, že 2-cyklová latencia nie je náhoda.

---

# 6. Pri korekcii daj komentár priamo k opravenému miestu

Napríklad v `hdmi_tx_core.sv` pri `period_d1`:

```systemverilog
// Pipeline alignment:
// - video/control/TERC4 encoders have 2-cycle output latency.
// - scheduler period_o is generated one cycle ahead of mux selection.
// - period_d1 is therefore the mux-select stage aligned with encoder outputs.
// Verified by tb_hdmi_tx_core_32x10:
//   * VIDEO only when de_r_d2 is active
//   * DATA_PAYLOAD emits exactly 32 TERC4 symbols
//   * no DATA_PAYLOAD overlaps active video
always_ff @(posedge pix_clk_i) begin
  if (!rst_ni)
    period_d1 <= HDMI_PERIOD_CONTROL;
  else
    period_d1 <= period;
end
```

Ak neskôr zistíš, že potrebuješ `period_d2`, komentár upravíš spolu s testom.

---

# 7. Vytvor `docs/HDMI_PIPELINE.md`

Toto by som určite spravil. Nemusí byť dlhé, ale má fixovať architektúru.

Napríklad:

```markdown
# HDMI TX Pipeline Notes

## Encoder latency

| Block | Latency |
|---|---:|
| tmds_video_encoder | 2 pixclk |
| tmds_control_encoder | 2 pixclk |
| terc4_encoder | 2 pixclk |
| hdmi_channel_mux | 1 pixclk registered output |

## Period alignment

`hdmi_period_scheduler.period_o` is the scheduler-stage period.
`hdmi_tx_core.period_d1` is the mux selection period.

The following relationship is expected in simulation:

- `period_o == HDMI_PERIOD_VIDEO` aligns with `de_r_d1`
- `period_d1 == HDMI_PERIOD_VIDEO` aligns with `de_r_d2`

## Data island payload

A data island consists of:

- 8 cycles DATA_PREAMBLE
- 2 cycles DATA_GB_LEAD
- 32 cycles DATA_PAYLOAD
- 2 cycles DATA_GB_TRAIL

The final output `ch0/ch1/ch2` must emit TERC4 encoded payload symbols 0..31 exactly once.
```

Takýto dokument je veľmi užitočný pri ďalších refaktoroch.

---

# 8. Vytvor `docs/TEST_MATRIX.md`

Tam zapíš aktuálne potvrdené kombinácie:

```markdown
# HDMI TX Test Matrix

Date: 2026-05-13

## Hardware monitor test

Resolution: 800x600@60
Pixel clock: 40 MHz
TMDS clock x5: 200 MHz

| ENABLE_AUDIO | ENABLE_DATA_ISLAND | Result |
|---:|---:|---|
| 0 | 0 | PASS - video visible |
| 0 | 1 | PASS - video visible |
| 1 | 0 | PASS - video visible |
| 1 | 1 | FAIL - monitor sleep |

## Simulation

| Test | Result | Notes |
|---|---|---|
| tb_hdmi_bch_ecc | PASS | Header/subpacket ECC vectors |
| tb_data_island_formatter | PASS | AVI formatter symbols |
| tb_hdmi_period_scheduler | PASS | Period lengths |
| tb_hdmi_tx_core_32x10 | PASS | 4 frames, no period overlap |
```

Keď opravíš audio, doplníš:

```markdown
| 1 | 1 | PASS - video visible, audio detected |
```

---

# 9. Zaviesť `CHANGELOG.md`

Pri každej korekcii zapíš stručne:

```markdown
## 2026-05-13

### Fixed
- Changed `terc4_encoder` latency from 1 cycle to 2 cycles.
- Reason: match TMDS video/control encoder latency and align data island payload with mux period.
- Verified by:
  - tb_terc4_encoder
  - tb_hdmi_tx_core_32x10

### Added
- Added debug parameters:
  - ENABLE_ACR_PACKET
  - ENABLE_AUDIO_INFOFRAME
  - ENABLE_AUDIO_SAMPLE

### Known issues
- Full audio + data island still fails on monitor.
- ACR packet builder/testbench byte order needs confirmation.
```

Toto nie je náhrada za git commit, ale je to veľmi dobrý vývojový denník.

---

# 10. Commit správy píš podľa príčiny, nie iba podľa súboru

Namiesto:

```text
update hdmi files
```

radšej:

```text
hdmi: align TERC4 latency with TMDS encoder pipeline
```

Alebo:

```text
sim: add 32x10 HDMI core regression for data island timing
```

Alebo:

```text
hdmi: gate audio packet sources with debug enable parameters
```

Ideálny commit popis:

```text
hdmi: align TERC4 latency with TMDS encoder pipeline

TERC4 encoder now has 2-cycle output latency, matching video and
control TMDS encoders. This prevents data island payload symbols from
being selected by the channel mux one cycle earlier than the other paths.

Verified by:
- tb_terc4_encoder
- tb_hdmi_tx_core_32x10

Related issue:
- monitor sleeps when ENABLE_AUDIO=1 and ENABLE_DATA_ISLAND=1
```

---

# 11. Označ zafixované správanie pomocou assertions

Najlepšie „dokumentovanie správania“ je assertion priamo v teste.

Napríklad v `tb_hdmi_tx_core_32x10.sv`:

```systemverilog
// Contract: data payload must never overlap active video at mux stage.
always_ff @(posedge pix_clk) begin
  if (rst_n) begin
    if (period_d1 == HDMI_PERIOD_DATA_PAYLOAD && de_r_d2) begin
      errors++;
      $error("DATA_PAYLOAD overlaps active video at mux stage");
    end
  end
end
```

Alebo:

```systemverilog
// Contract: mux-stage VIDEO period must align with encoder-aligned DE.
always_ff @(posedge pix_clk) begin
  if (rst_n) begin
    if ((period_d1 == HDMI_PERIOD_VIDEO) != de_r_d2) begin
      errors++;
      $error("VIDEO/de alignment mismatch at mux stage");
    end
  end
end
```

Takto sa správanie nielen popíše, ale aj automaticky stráži.

---

# 12. Pre známe odchýlky používaj komentár `INTENTIONAL`

Ak je nejaký 1-cyklový posun zámerný, zapíš to jasne:

```systemverilog
// INTENTIONAL PIPELINE OFFSET:
// period_o is one cycle ahead of the encoder-aligned DE.
// Do not compare period_o directly against de_r.
// Use period_d1 against de_r_d2 for mux-stage assertions.
// Verified by tb_hdmi_tx_core_32x10.
```

To je oveľa lepšie než nechať budúceho seba hádať, či je to bug.

---

# 13. Pri opravách v RTL používaj krátke „why“ komentáre

Nie:

```systemverilog
// delay period
```

Lepšie:

```systemverilog
// Delay scheduler period to align mux selection with 2-cycle TMDS/TERC4
// encoder outputs.
```

Nie:

```systemverilog
// advance formatter
```

Lepšie:

```systemverilog
// Lookahead advance: formatter must present the next payload nibble early
// enough for the 2-cycle TERC4 encoder and registered channel mux.
```

Komentár má vysvetliť dôvod, nie zopakovať kód.

---

# 14. Zaveď issue/bug ID aj v komentároch a testoch

Napríklad:

```text
HDMI-BUG-001: monitor sleeps when audio and data island are both enabled
HDMI-BUG-002: TERC4 latency mismatch
HDMI-BUG-003: data island payload shifted by one symbol
HDMI-BUG-004: ACR byte-order mismatch between builder and testbench
```

V `docs/bugs/HDMI-BUG-001.md`:

```markdown
# HDMI-BUG-001: Monitor sleeps when audio and data island are enabled

## Symptom

| ENABLE_AUDIO | ENABLE_DATA_ISLAND | Result |
|---:|---:|---|
| 0 | 0 | pass |
| 0 | 1 | pass |
| 1 | 0 | pass |
| 1 | 1 | monitor sleep |

## Suspected causes

- data island payload alignment
- ACR layout
- audio sample packet layout

## Confirmed fixes

- TERC4 latency changed to 2 cycles

## Required tests

- tb_hdmi_tx_core_32x10 payload content check
- ACR-only hardware test
- AudioIF-only hardware test
- Sample-only hardware test
```

Toto ti veľmi pomôže pri dlhšom vývoji.

---

# 15. Odporúčaná minimálna dokumentačná sada

Do projektu by som pridal:

```text
docs/
  HDMI_PIPELINE.md
  HDMI_PACKET_LAYOUT.md
  TEST_MATRIX.md
  BUGS.md
  CHANGELOG.md

sim/
  golden/
  logs/
  reports/
```

A do každého kritického RTL modulu:

```text
Behavior contract
Latency
Input/output handshake
Verified by
Known assumptions
```

---

# Praktický najbližší krok

Teraz by som spravil toto:

```text
1. Vytvor docs/TEST_MATRIX.md
2. Vytvor docs/HDMI_PIPELINE.md
3. Uprav Makefile tak, aby ukladal logy do sim/logs/
4. Do každého testbenchu pridaj jednotný PASS/FAIL banner
5. Do RTL modulov pridaj krátky Behavior contract
6. Pri každom fix-e sprav git commit s odkazom na testy
```

Najdôležitejšie je, aby každá oprava mala túto stopu:

```text
problém → korekcia → test → výsledok → commit
```

Napríklad:

```text
HDMI-BUG-002
Problém: TERC4 mal 1-cycle latency, ostatné encodery 2-cycle.
Korekcia: pridaný vstupný register do terc4_encoder.
Test: tb_terc4_encoder + tb_hdmi_tx_core_32x10.
Výsledok: PASS.
Commit: hdmi: align TERC4 latency with encoder pipeline
```

Toto je najlepší spôsob, ako zafixovať správne správanie modulov a zároveň si udržať kontrolu nad tým, čo sa v HDMI jadre mení.
