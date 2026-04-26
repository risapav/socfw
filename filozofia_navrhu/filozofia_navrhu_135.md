## Commit 258 — reset usage analysis

```text
rtl: add reset usage analysis before top-level reset emission
```

Cieľ:

* negenerovať `RESET_N`, `reset_active`, `reset_n`, ak ich žiadny modul nepoužíva
* odstrániť Quartus warningy typu:

```text
object "reset_n" assigned a value but never read
No output dependent on input pin "RESET_N"
```

Pravidlo:

* ak aspoň jedno IP má `reset.port`, reset sa emituje
* ak timing clock má reset, ale žiadne IP reset nepoužíva, dať warning:

```text
RST001 timing reset is declared but no instantiated IP consumes reset
```

---

## Commit 259 — reset-aware blink example

```text
examples: make blink_test_01 reset-aware
```

Upraviť `blink_test.sv`:

```systemverilog
module blink_test #(
  parameter integer CLK_FREQ = 50000000
)(
  input  wire       clk_i,
  input  wire       rst_ni,
  output reg  [5:0] leds_o
);
```

A `blink_test.ip.yaml`:

```yaml
reset:
  port: rst_ni
  active_high: false

ports:
  - name: clk_i
    direction: input
    width: 1
  - name: rst_ni
    direction: input
    width: 1
  - name: leds_o
    direction: output
    width: 6
```

Potom `RESET_N` bude reálne používaný.

---

## Commit 260 — SDC `derive_clock_uncertainty`

```text
emit: support derive_clock_uncertainty in timing SDC
```

Z:

```yaml
timing:
  derive_uncertainty: true
```

emitovať:

```tcl
derive_clock_uncertainty
```

Umiestniť po `create_clock`.

---

## Commit 261 — SDC IO delay min/max support

```text
emit: emit min and max IO delays from timing config
```

Z:

```yaml
io_delays:
  default_output_max_ns: 3.0
  default_output_min_ns: 0.0
```

emitovať:

```tcl
set_output_delay -clock SYS_CLK -max 3.000 [get_ports {ONB_LEDS[*]}]
set_output_delay -clock SYS_CLK -min 0.000 [get_ports {ONB_LEDS[*]}]
```

Doplniť schema:

```yaml
default_input_min_ns
default_output_min_ns
```

---

## Commit 262 — exclude clock/reset from auto IO delays

```text
emit: exclude clock and reset ports from auto IO delay generation
```

Namiesto:

```tcl
set_input_delay -clock SYS_CLK -max 3.000 [all_inputs]
```

použiť explicitné porty:

```tcl
set_output_delay -clock SYS_CLK -max 3.000 [get_ports {ONB_LEDS[*]}]
```

Clock port `SYS_CLK` a reset `RESET_N` nikdy nedávať do `set_input_delay`.

---

## Commit 263 — SDC override expansion for vector ports

```text
emit: expand IO delay overrides for vector board ports
```

Z:

```yaml
overrides:
  - port: ONB_LEDS[*]
    direction: output
    clock: SYS_CLK
    max_ns: 3.0
    min_ns: 0.0
```

emitovať:

```tcl
set_output_delay -clock SYS_CLK -max 3.000 [get_ports {ONB_LEDS[*]}]
set_output_delay -clock SYS_CLK -min 0.000 [get_ports {ONB_LEDS[*]}]
```

Nie generovať per-bit, ak Quartus akceptuje wildcard.

---

## Commit 264 — async reset SDC handling

```text
emit: add canonical async reset false path handling
```

Z:

```yaml
false_paths:
  - from_port: RESET_N
    comment: Async reset
```

emitovať:

```tcl
# Async reset
set_false_path -from [get_ports {RESET_N}]
```

---

## Commit 265 — prevent duplicate SDC inclusion

```text
emit: prevent duplicate SDC inclusion in Quartus helper scripts
```

Pravidlo:

* `files.tcl` obsahuje:

```tcl
set_global_assignment -name SDC_FILE "../timing/soc_top.sdc"
```

* `project.tcl` nesmie obsahovať:

```tcl
source ../timing/soc_top.sdc
```

---

## Commit 266 — IO standard assignments in board.tcl

```text
emit: add IO_STANDARD assignments to board.tcl
```

Pre scalar:

```tcl
set_location_assignment W13 -to RESET_N
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to RESET_N
```

Pre vector:

```tcl
set_location_assignment E4 -to ONB_LEDS[0]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to ONB_LEDS[0]
```

---

## Commit 267 — board.tcl selected resources only

```text
emit: emit board.tcl only for selected and bound resources
```

Zníži:

```text
Some pins have incomplete I/O assignments
```

lebo board.tcl nebude emitovať alternatívne/nepoužité resources.

Vždy emitovať:

* system clock
* reset iba ak je použitý
* bindované resources
* explicitné `features.use`

---

## Commit 268 — Quartus timing clean blink regression

```text
golden: add timing-clean blink_test_01 regression
```

Golden assertions:

```python
assert "derive_clock_uncertainty" in sdc
assert "set_false_path -from [get_ports {RESET_N}]" in sdc
assert "set_output_delay -clock SYS_CLK -max" in sdc
assert "set_output_delay -clock SYS_CLK -min" in sdc
assert "IO_STANDARD" in board_tcl
```

---

## Commit 269 — SDC diagnostics for missing min delays

```text
validate: warn when IO delays define max but no min
```

Ak timing má:

```yaml
default_output_max_ns: 3.0
```

ale nemá:

```yaml
default_output_min_ns
```

warning:

```text
TIM201 output max delay is set but output min delay is missing
```

---

## Commit 270 — timing config docs for Quartus-clean projects

```text
docs: document Quartus-clean timing_config.yaml
```

Ukážkový timing:

```yaml
version: 2
kind: timing

timing:
  derive_uncertainty: true

  clocks:
    - name: SYS_CLK
      source: SYS_CLK
      period_ns: 20.0
      reset:
        source: RESET_N
        active_low: true
        sync_stages: 2

  false_paths:
    - from_port: RESET_N
      comment: Async reset

  io_delays:
    auto: true
    clock: SYS_CLK
    default_output_max_ns: 3.0
    default_output_min_ns: 0.0
```

---

Najbližší praktický blok by som spravil takto:

```text
260 derive_clock_uncertainty
261 min/max IO delays
262 exclude clock/reset from IO delays
264 async reset false path
266 IO_STANDARD assignments
259 reset-aware blink example
```

To priamo odstráni väčšinu warningov z tvojho Quartus logu.
