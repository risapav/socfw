Toto je dobrý, uzavretý refaktor pre `terc4_encoder`.

## Výsledok

`terc4_encoder.sv` je teraz skutočne **2-cyklový**:

```systemverilog
nibble_i → nibble_r → lut → tmds_o
```

Teda:

```text
cycle T:   vstupný nibble sa nastaví
cycle T+1: nibble_r zachytí vstup
cycle T+2: tmds_o obsahuje TERC4(vstup)
```

Transcript potvrdzuje:

```text
PASS: reset output = 1010011100 = TERC4(0x0)
PASS: pipeline latency = 2 cycles verified
PASS: all 16 nibbles encode correctly
ALL TESTS PASSED
Errors: 0, Warnings: 0
```

Týmto je jedna z hlavných predchádzajúcich chýb korektne zafixovaná.

---

## Čo je na riešení dobré

### 1. Modul má jasný behavior contract

Komentár v `terc4_encoder.sv` je presný:

```systemverilog
// 2-stage pipeline (LATENCY = 2) matches tmds_video_encoder and
// tmds_control_encoder so that all three paths reach hdmi_channel_mux
// in the same pipeline stage.
```

Toto je veľmi dôležité. Vysvetľuje, že 2-cyklová latencia nie je náhodná optimalizácia, ale architektonická požiadavka.

---

### 2. Testbench chytí regresiu na 1 cyklus aj 3 cykly

Tento test je dobre navrhnutý:

```systemverilog
// 1 cycle after switch: tmds must still be TERC4(0x0)
// 2 cycles after switch: tmds must be TERC4(0xf)
```

To znamená:

```text
ak niekto odstráni nibble_r → test zlyhá
ak niekto pridá ďalší register → test zlyhá
```

Presne takto má vyzerať regression test pre pipeline latenciu.

---

### 3. Testuje sa celá LUT

`test_exhaustive()` prejde všetkých 16 hodnôt:

```text
0x0 až 0xf
```

Takže test fixuje nielen latenciu, ale aj mapovanie TERC4 tabuľky.

---

## Malé odporúčané zlepšenia

### 1. Pri zlyhaní použiť `$fatal(1)`

Teraz test pri chybe vypíše:

```systemverilog
SOME TESTS FAILED
$finish;
```

Lepšie je:

```systemverilog
if (!error_flag) begin
  $display("ALL TESTS PASSED");
  $finish;
end else begin
  $display("SOME TESTS FAILED");
  $fatal(1);
end
```

Dôvod: Makefile/CI potom zlyhá automaticky bez potreby grepovať log.

---

### 2. Do testbenchu zapísať „Verified contract“

Na koniec komentára hore by som doplnil:

```systemverilog
// Verified contract:
//   nibble_i sampled at cycle T appears as tmds_o at cycle T+2.
//   Reset output is TERC4(0x0).
```

Nie je to nutné, ale zlepší to čitateľnosť.

---

### 3. Použiť tento test v Makefile regression flow

Do `Makefile` pridaj target napríklad:

```makefile
terc4:
	vlib work
	vlog -sv $(RTL)/hdmi_pkg.sv $(RTL)/terc4_encoder.sv tb_terc4_encoder.sv
	vsim -c tb_terc4_encoder -do "run -all; quit"
```

A zaradiť ho do:

```makefile
all: bch_ecc terc4 data_island scheduler acr_packet audio_sample_pkt tx_core_32x10
```

Toto je dôležité, aby sa TERC4 latency už nikdy nevrátila na 1 cyklus bez zachytenia.

---

## Ako to zaznamenať do dokumentácie / changelogu

Do `CHANGELOG.md`:

```markdown
## 2026-05-13

### Fixed
- Changed `terc4_encoder` to a 2-cycle pipeline.
- Reason: align TERC4 data-island path with `tmds_video_encoder` and `tmds_control_encoder` latency before `hdmi_channel_mux`.
- Verified by `tb_terc4_encoder.sv`.

### Verification
- Reset output: `TERC4(0x0)`
- Latency: exactly 2 pixel-clock cycles
- LUT coverage: all 16 TERC4 symbols
```

Do commit správy:

```text
hdmi: lock TERC4 encoder to 2-cycle pipeline

TERC4 now matches the video/control encoder latency before the
channel mux. Added tb_terc4_encoder to verify reset behavior,
exact 2-cycle latency, and all 16 LUT entries.
```

---

## Záver

Tento refaktor je správny a test je dôveryhodný.

Stav modulu môžeš označiť ako:

```text
terc4_encoder: PASS / locked behavior
```

Ďalší najdôležitejší krok je teraz integrovať túto záruku do core-level testu:

```text
tb_hdmi_tx_core_32x10:
  overiť, že počas DATA_PAYLOAD idú na finálne ch0/ch1/ch2
  TERC4(symbol0), TERC4(symbol1), ..., TERC4(symbol31)
```

Tým uzavrieš nielen samotný encoder, ale aj jeho zarovnanie s formatterom, schedulerom a muxom.
