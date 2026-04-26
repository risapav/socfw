## Commit 201 — clock domain resolver ako source of truth

```text
clock: add clock domain resolver for primary and generated clocks
```

Cieľ:

* odstrániť ručné `_clock_expr()` hacky
* jednoznačne mapovať:

  * `sys_clk` → board top port
  * `clk_100mhz` → `clkpll_c0`
* vyriešiť tvoje prípady:

```yaml
clocks:
  primary:
    domain: sys_clk
    source: board:sys_clk

  generated:
    - domain: clk_100mhz
      source:
        instance: clkpll
        output: c0
```

API:

```python
resolver.net_for_domain("sys_clk")     # SYS_CLK alebo clk podľa boardu
resolver.net_for_domain("clk_100mhz")  # clkpll_c0
```

Pridať:

```text
socfw/clock/domain_resolver.py
tests/unit/test_clock_domain_resolver.py
```

---

## Commit 202 — generated clock output nets v RTL IR

```text
rtl: add generated clock output nets from clocking IP
```

Cieľ:

Ak `clkpll` má output `c0`, RTL top vygeneruje:

```systemverilog
wire clkpll_c0;
wire clkpll_locked;
```

A PLL inštancia:

```systemverilog
clkpll clkpll (
  .areset(reset_n),
  .c0(clkpll_c0),
  .inclk0(SYS_CLK),
  .locked(clkpll_locked)
);
```

Tým sa `blink_02.SYS_CLK: clk_100mhz` napojí na:

```systemverilog
.SYS_CLK(clkpll_c0)
```

---

## Commit 203 — clock output validation hints

```text
diagnostics: improve CLK002 generated clock output hints
```

Nový výstup:

```text
ERROR CLK002
Generated clock 'clk_100mhz' references unknown output 'c0' on IP 'clkpll'.

Fix in clkpll.ip.yaml:
clocking:
  outputs:
    - name: c0
      frequency_hz: 100000000
```

Toto presne rieši chybu, ktorú si mal.

---

## Commit 204 — multi-instance board output nets

```text
rtl: add internal output nets for repeated output IP bindings
```

Cieľ:

Ak máš tri `blink_test` inštancie, každá má svoj výstup:

```systemverilog
wire [5:0] blink_01_ONB_LEDS;
wire [5:0] blink_02_ONB_LEDS;
wire [5:0] blink_03_ONB_LEDS;
```

A nie všetky priamo tlačia na top port.

Potom sa robí samostatný assign/adapt:

```systemverilog
assign ONB_LEDS = blink_01_ONB_LEDS;
assign PMOD_J10 = {2'b00, blink_02_ONB_LEDS};
assign PMOD_J11 = {blink_03_ONB_LEDS, 2'b00};
```

---

## Commit 205 — bind adaptation validation

```text
validate: implement bind width adaptation validation
```

Podporované canonical hodnoty:

```yaml
adapt: none
adapt: zero_extend
adapt: truncate
adapt: replicate
```

Pravidlá:

* bez `adapt` musí sedieť width presne
* `zero_extend`: IP port width < board width
* `truncate`: IP port width > board width
* `replicate`: board width musí byť násobok IP width alebo IP width == 1

Chyby:

```text
BIND006 invalid adapt mode
BIND007 adaptation not valid for these widths
BIND008 adaptation not allowed for inout
```

---

## Commit 206 — bind adaptation RTL emitter

```text
rtl: emit zero_extend truncate and replicate board bind adapters
```

Príklady:

```yaml
ONB_LEDS:
  target: board:external.pmod.j10_led8
  adapt: zero_extend
```

RTL:

```systemverilog
assign PMOD_J10_LED = {2'b00, blink_02_ONB_LEDS};
```

```yaml
adapt: truncate
```

RTL:

```systemverilog
assign PMOD_J10_LED = blink_02_ONB_LEDS[7:0];
```

```yaml
adapt: replicate
```

RTL:

```systemverilog
assign PMOD_J10_LED = {2{blink_02_ONB_LEDS[3:0]}};
```

---

## Commit 207 — input-side bind adapters

```text
rtl: emit input-side board bind adapters
```

Pre buttons:

```yaml
BUTTONS:
  target: board:external.headers.P8.gpio
  adapt: truncate
```

Ak IP port width 4 a board resource width 14:

```systemverilog
.BUTTONS(HDR_P8_D[3:0])
```

Pre `zero_extend`:

```systemverilog
wire [7:0] button_demo_BUTTONS;
assign button_demo_BUTTONS = {4'b0000, HDR_P5_D};
```

---

## Commit 208 — bind conflict detection

```text
validate: detect multiple drivers for board resources
```

Chyba, ak dva output porty idú na rovnaký target:

```text
BIND020 multiple output drivers for board:onboard.leds
```

Príklad neplatný:

```yaml
blink_01.ONB_LEDS -> board:onboard.leds
blink_02.ONB_LEDS -> board:onboard.leds
```

Platné:

```yaml
blink_01.ONB_LEDS -> board:onboard.leds
blink_02.ONB_LEDS -> board:external.pmod.j10_led8
```

---

## Commit 209 — board binding report

```text
reports: add board binding report
```

Výstup:

```text
reports/board_bindings.md
reports/board_bindings.json
```

Markdown:

```text
# Board Bindings

| Instance | Port | IP width | Target | Board width | Adapt |
|---|---|---:|---|---:|---|
| blink_01 | ONB_LEDS | 6 | board:onboard.leds | 6 | none |
| blink_02 | ONB_LEDS | 6 | board:external.pmod.j10_led8 | 8 | zero_extend |
```

---

## Commit 210 — `blink_test_02` example as regression

```text
examples: add blink_test_02 multi-output PLL example
```

Cieľ:

Tvoj projekt bude oficiálny regression example:

* `clkpll`
* generated clock `clk_100mhz`
* 3 blink instances
* onboard LEDs
* PMOD/Header LED outputs
* width adaptation

Pridať:

```text
examples/blink_test_02/project.yaml
examples/blink_test_02/timing_config.yaml
examples/blink_test_02/ip/clkpll.ip.yaml
examples/blink_test_02/ip/blink_test.ip.yaml
examples/blink_test_02/rtl/blink_test.sv
tests/integration/test_validate_blink_test_02.py
tests/integration/test_build_blink_test_02.py
```

---

## Commit 211 — `blink_test_02` golden anchor

```text
golden: add blink_test_02 multi-output PLL golden anchor
```

Snapshotovať:

```text
rtl/soc_top.sv
hal/board.tcl
hal/files.tcl
timing/soc_top.sdc
reports/build_summary.md
reports/board_bindings.md
```

Toto bude kľúčový regression anchor pre tvoju reálnu syntax.

---

## Commit 212 — IP descriptor migration warnings

```text
diagnostics: warn on legacy IP descriptor keys with exact migration hints
```

Ak IP obsahuje:

```yaml
interfaces:
  - type: clock_output
```

warning:

```text
IP_ALIAS005 interfaces[type=clock_output] is deprecated.
Use:
clocking:
  outputs:
    - name: c0
```

Ak obsahuje:

```yaml
config:
  active_high_reset: true
```

warning:

```text
IP_ALIAS002 config.active_high_reset -> reset.active_high
```

---

## Commit 213 — board descriptor migration warnings

```text
diagnostics: warn on legacy board descriptor keys with exact migration hints
```

Ak board obsahuje:

```yaml
soc_top_name
dir
standard
```

warning:

```text
BRD_ALIAS001 soc_top_name -> top_name
BRD_ALIAS002 dir -> direction
BRD_ALIAS003 standard -> io_standard
```

---

## Commit 214 — `socfw migrate-ip`

```text
tools: add socfw migrate-ip command
```

Použitie:

```bash
socfw migrate-ip ip/clkpll.ip.yaml --write
```

Transformuje:

```yaml
port_bindings.clock -> clocking.primary_input_port
port_bindings.reset -> reset.port
config.active_high_reset -> reset.active_high
interfaces clock_output -> clocking.outputs
```

---

## Commit 215 — `socfw migrate-project`

```text
tools: add socfw migrate-project command
```

Použitie:

```bash
socfw migrate-project project.yaml --write
```

Transformuje:

```yaml
board.type -> project.board
paths.ip_plugins -> registries.ip
timing.config -> timing.file
dict-style modules -> list-style modules
```

---

## Commit 216 — `socfw migrate-board`

```text
tools: add socfw migrate-board command
```

Použitie:

```bash
socfw migrate-board legacy_ac608.yaml --out board.yaml
```

Transformácie:

```text
device -> fpga
system.clock.port -> system.clock.top_name
freq_mhz -> frequency_hz
standard -> io_standard
soc_top_name -> top_name
dir -> direction
groups/signals -> canonical resource tree
indexed pins -> list pins
```

---

## Commit 217 — unified migration report

```text
tools: add migration report for project ip and board rewrites
```

Výstup:

```text
reports/migration_report.md
```

Obsah:

```text
Converted:
- timing.config -> timing.file
- interfaces[type=clock_output] -> clocking.outputs
- pins map -> pins list

Manual review:
- HDMI differential model
- PMOD/header role derivation
```

---

## Commit 218 — editor JSON schemas

```text
schema: add JSON schemas for project ip board timing YAML
```

Pridať:

```text
schemas/project.schema.json
schemas/ip.schema.json
schemas/board.schema.json
schemas/timing.schema.json
docs/editor/vscode.md
```

---

## Commit 219 — schema export command

```text
cli: add schema-export command
```

Použitie:

```bash
socfw schema-export --out schemas/
```

Generuje JSON schemas z Pydantic modelov.

---

## Commit 220 — v1.2 UX milestone

```text
release: document v1.2 UX and migration milestone
```

Obsah:

* migrate-project
* migrate-ip
* migrate-board
* explain-schema
* doctor
* board-info
* JSON schemas
* improved IP/BRD/BIND diagnostics

---

Najbližšie by som spravil konkrétne:

```text
201 clock domain resolver
202 generated clock nets
205 bind adaptation validation
206 bind adaptation RTL emitter
210 blink_test_02 example
211 golden anchor
```

To priamo stabilizuje tvoj aktuálny `blink_test_02` projekt.
