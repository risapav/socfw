## Commit 176 — native bus signal model

```text
rtl: add native bus signal model for simple_bus and wishbone
```

Cieľ:

* prestať mať bridge pripojený na konštanty
* zaviesť interné signály pre:

  * `simple_bus`
  * `wishbone`
* pripraviť reálne prepojenie CPU → bridge → SDRAM

Pridať:

```text
socfw/ir/bus.py
tests/unit/test_bus_signal_model.py
```

Model:

```python
@dataclass(frozen=True)
class BusSignal:
    name: str
    width: int = 1

@dataclass(frozen=True)
class BusSignalSet:
    prefix: str
    protocol: str
    signals: tuple[BusSignal, ...]
```

Podporované signály:

```text
simple_bus:
  addr[31:0]
  wdata[31:0]
  rdata[31:0]
  be[3:0]
  we
  valid
  ready

wishbone:
  adr[31:0]
  dat_w[31:0]
  dat_r[31:0]
  sel[3:0]
  we
  cyc
  stb
  ack
```

---

## Commit 177 — bus signal declarations in RTL top

```text
rtl: emit bus signal declarations for planned bridges
```

Cieľ:

Pre `sdram0` vytvoriť:

```systemverilog
wire [31:0] sdram0_sb_addr;
wire [31:0] sdram0_sb_wdata;
wire [31:0] sdram0_sb_rdata;
wire [3:0]  sdram0_sb_be;
wire        sdram0_sb_we;
wire        sdram0_sb_valid;
wire        sdram0_sb_ready;

wire [31:0] sdram0_wb_adr;
wire [31:0] sdram0_wb_dat_w;
wire [31:0] sdram0_wb_dat_r;
wire [3:0]  sdram0_wb_sel;
wire        sdram0_wb_we;
wire        sdram0_wb_cyc;
wire        sdram0_wb_stb;
wire        sdram0_wb_ack;
```

Upraviť:

```text
socfw/builders/rtl_ir_builder.py
socfw/emit/rtl_emitter.py
tests/unit/test_rtl_ir_builder_bus_signals.py
```

---

## Commit 178 — bridge-to-wishbone wiring

```text
rtl: wire planned bridge outputs to wishbone peripheral ports
```

Cieľ:

Bridge už nebude:

```systemverilog
.wb_adr()
.wb_dat_w()
```

ale:

```systemverilog
.wb_adr(sdram0_wb_adr)
.wb_dat_w(sdram0_wb_dat_w)
.wb_dat_r(sdram0_wb_dat_r)
.wb_sel(sdram0_wb_sel)
.wb_we(sdram0_wb_we)
.wb_cyc(sdram0_wb_cyc)
.wb_stb(sdram0_wb_stb)
.wb_ack(sdram0_wb_ack)
```

A `sdram_ctrl sdram0` dostane:

```systemverilog
.wb_adr(sdram0_wb_adr)
.wb_dat_w(sdram0_wb_dat_w)
.wb_dat_r(sdram0_wb_dat_r)
...
```

---

## Commit 179 — CPU simple_bus master wiring

```text
rtl: wire CPU simple_bus master to planned bridge simple_bus side
```

Cieľ:

CPU `dummy_cpu` alebo reálny CPU sa pripojí:

```systemverilog
.bus_addr(sdram0_sb_addr)
.bus_wdata(sdram0_sb_wdata)
.bus_rdata(sdram0_sb_rdata)
.bus_be(sdram0_sb_be)
.bus_we(sdram0_sb_we)
.bus_valid(sdram0_sb_valid)
.bus_ready(sdram0_sb_ready)
```

Pridať mapovanie z `CpuDescriptor.bus_master`.

---

## Commit 180 — single-slave simple_bus fabric

```text
rtl: add single-slave simple_bus fabric wiring
```

Cieľ:

Pre projekty s jedným bus slave netreba decoder.

Pravidlo:

* ak fabric `main` má presne jeden slave, CPU master sa priamo napojí na ten slave/bridge
* ak má viac, zatiaľ error:

```text
BUS010 multiple simple_bus slaves require address decoder
```

---

## Commit 181 — simple_bus address decoder scaffold

```text
rtl: add simple_bus address decoder scaffold for multiple slaves
```

Cieľ:

Podpora viac modulov na jednom fabric:

```yaml
modules:
  - instance: uart0
    bus:
      fabric: main
      base: 0x10000000
      size: 0x1000

  - instance: sdram0
    bus:
      fabric: main
      base: 0x80000000
      size: 0x01000000
```

Výstup:

```systemverilog
simple_bus_decoder u_main_decoder (...);
```

---

## Commit 182 — address range validation

```text
validate: add bus address range overlap checks
```

Chyby:

```text
BUS020 module uart0 range overlaps sdram0
BUS021 module sdram0 size must be power-of-two aligned
BUS022 module sdram0 base must align to size
```

---

## Commit 183 — bus map report

```text
reports: emit bus_map.md and bus_map.json
```

Výstup:

```text
reports/bus_map.md
reports/bus_map.json
```

Markdown:

```text
# Bus Map

## Fabric main

| Instance | Protocol | Base | Size |
|---|---|---:|---:|
| sdram0 | wishbone via simple_bus_to_wishbone | 0x80000000 | 0x01000000 |
```

---

## Commit 184 — bus map golden anchor for SDRAM

```text
golden: snapshot bus map for vendor_sdram_soc
```

Pridať:

```text
tests/golden/expected/vendor_sdram_soc/reports/bus_map.md
tests/golden/expected/vendor_sdram_soc/reports/bus_map.json
```

---

## Commit 185 — real SDRAM bridge-visible build milestone

```text
golden: update vendor_sdram_soc for real bridge wiring
```

Cieľ:

`vendor_sdram_soc` už nebude scaffold-only.

Golden `soc_top.sv` má ukazovať:

* CPU bus master
* bridge simple_bus side
* bridge wishbone side
* SDRAM wishbone slave side

---

## Commit 186 — reset synchronization primitive

```text
rtl: add reset synchronizer primitive and IR support
```

Pridať:

```text
socfw/rtl_primitives/reset_sync.sv
```

RTL:

```systemverilog
module reset_sync #(
  parameter integer STAGES = 2
)(
  input wire clk,
  input wire async_reset_n,
  output wire sync_reset_n
);
```

---

## Commit 187 — reset policy from timing clock reset config

```text
rtl: generate reset synchronizers from timing reset policy
```

Z `timing_config.yaml`:

```yaml
reset:
  port: RESET_N
  active_low: true
  sync_stages: 2
```

vygenerovať:

```systemverilog
reset_sync #(.STAGES(2)) u_reset_sync_sys_clk (...);
```

---

## Commit 188 — reset report

```text
reports: add reset strategy summary
```

Markdown:

```text
## Reset Strategy
- async input: RESET_N active low
- sys_clk sync stages: 2
- generated reset net: reset_n
```

---

## Commit 189 — generated clocks wiring

```text
rtl: wire generated clock outputs from clocking IP
```

Cieľ:

PLL output:

```yaml
source:
  instance: clkpll
  output: c0
```

vygeneruje net:

```systemverilog
wire clkpll_c0;
```

a spojenie:

```systemverilog
clkpll clkpll (
  .inclk0(SYS_CLK),
  .c0(clkpll_c0),
  .locked(clkpll_locked)
);
```

Modul používajúci `clk_100mhz` dostane:

```systemverilog
.SYS_CLK(clkpll_c0)
```

---

## Commit 190 — clock domain resolver

```text
clock: add clock domain resolver for primary and generated clocks
```

API:

```python
resolver.net_for_domain("sys_clk") -> "SYS_CLK"
resolver.net_for_domain("clk_100mhz") -> "clkpll_c0"
```

Použiť v RTL builderi namiesto ručného `_clock_expr`.

---

## Commit 191 — PLL lock reset policy

```text
rtl: support PLL lock gated reset policy
```

Project/timing syntax:

```yaml
clocks:
  generated:
    - domain: clk_100mhz
      source:
        instance: clkpll
        output: c0
      reset:
        gated_by:
          instance: clkpll
          output: locked
        sync_stages: 2
```

RTL:

```systemverilog
wire clkpll_locked;
wire reset_clk_100mhz_n;
assign pll_reset_ok = RESET_N & clkpll_locked;
```

---

## Commit 192 — clock/reset domain report

```text
reports: add clock and reset domain report
```

Výstup:

```text
reports/clock_domains.md
```

Obsah:

```text
sys_clk:
  source: board SYS_CLK
  reset: RESET_N sync 2

clk_100mhz:
  source: clkpll.c0
  reset: RESET_N gated by clkpll.locked sync 2
```

---

## Commit 193 — timing SDC generated clock improvements

```text
emit: improve generated clock SDC using clock domain resolver
```

SDC:

```tcl
create_generated_clock -name clk_100mhz \
  -source [get_ports {SYS_CLK}] \
  [get_pins {clkpll|c0}]
```

---

## Commit 194 — PLL example golden anchor

```text
golden: add PLL generated clock native wiring anchor
```

Pridať:

```text
tests/golden/fixtures/pll_native/project.yaml
tests/golden/expected/pll_native/rtl/soc_top.sv
tests/golden/expected/pll_native/timing/soc_top.sdc
```

---

## Commit 195 — blink_test multi-output example

```text
examples: add blink_test_02 multi-output board resource example
```

Tvoj prípad:

* onboard LEDs
* PMOD/Header LEDs
* generated PLL clock
* width adapters

Pridať:

```text
examples/blink_test_02/project.yaml
examples/blink_test_02/timing_config.yaml
tests/integration/test_validate_blink_test_02.py
```

---

## Commit 196 — width adapter RTL for multi-output blink

```text
rtl: emit width adapters for multi-output blink example
```

Napríklad:

```yaml
ONB_LEDS:
  target: board:external.pmod.j10_led8
  adapt: zero_extend
```

RTL:

```systemverilog
wire [5:0] blink_02_ONB_LEDS;
assign PMOD_J10_LED = {2'b00, blink_02_ONB_LEDS};
```

---

## Commit 197 — multi-instance top signal naming

```text
rtl: stabilize internal signal naming for repeated IP instances
```

Pravidlo:

```text
<instance>_<port>
```

Napr.:

```systemverilog
wire [5:0] blink_01_ONB_LEDS;
wire [5:0] blink_02_ONB_LEDS;
```

---

## Commit 198 — bind conflict validation

```text
validate: detect multiple drivers for same board resource
```

Ak dva output porty bindujú rovnaký target:

```yaml
blink_01.ONB_LEDS -> board:onboard.leds
blink_02.ONB_LEDS -> board:onboard.leds
```

chyba:

```text
BIND020 multiple output drivers for board:onboard.leds
```

---

## Commit 199 — top-level resource assignment report

```text
reports: add board binding report
```

Markdown:

```text
# Board Bindings

| Instance | Port | Direction | Target | Adapt |
|---|---|---|---|---|
| blink_01 | ONB_LEDS | output | board:onboard.leds | none |
| blink_02 | ONB_LEDS | output | board:external.pmod.j10_led8 | zero_extend |
```

---

## Commit 200 — v1.2 native RTL milestone notes

```text
release: document v1.2 native RTL and bus wiring milestone
```

Obsah:

* real bridge wiring
* generated clocks
* reset synchronization
* bus map
* width adapters
* board binding report

---

Najbližšie by som implementoval blok:

```text
189 clock domain resolver + generated clock wiring
195 blink_test_02 example
196 width adapters
198 bind conflict validation
199 board binding report
```

To priamo vyrieši tvoju aktuálnu triedu projektov: viac blink modulov, PLL clock, rôzne board výstupy a adaptácia šírok.
