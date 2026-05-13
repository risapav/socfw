# Getting Started

## Installation

```sh
git clone <repo>
cd socfw
pip install -e .
```

## Basic workflow

```sh
socfw validate project.yaml          # check YAML correctness + design rules
socfw build project.yaml --out build  # generate all artifacts
```

## CLI reference

### `socfw build`

```sh
socfw build <project.yaml> [--out DIR] [--trace]
```

Generates all artifacts into `--out` (default: `build`):

| Output | Description |
|---|---|
| `rtl/soc_top.sv` | Top-level SystemVerilog module |
| `sim/tb_soc_top.sv` | Auto-generated simulation testbench |
| `sim/files.f` | iverilog filelist |
| `timing/soc_top.sdc` | Timing constraints (Quartus) |
| `hal/files.tcl` | Source filelist TCL (Quartus) |
| `hal/board.tcl` | Pin assignment TCL (Quartus) |
| `reports/build_summary.md` | Build provenance report |

**`--trace`** — prints the RTL IR to stderr after building, useful for debugging wiring:

```sh
socfw build project.yaml --out build --trace 2>trace.txt
```

Output format:
```
[trace] RtlTop: soc_top
─── ports (9) ──────────────────────────────────────────
  input  SYS_CLK
  input  RESET_N
  output [4:0] VGA_R
  ...
─── signals (14) ───────────────────────────────────────
  wire clkpll_c0
  wire reset_n
  wire w_clkpll_locked
  ...
─── adapt_assigns (1) ──────────────────────────────────
  reset_n = w_rst_sync0_rst_no
─── instances (8) ──────────────────────────────────────
  clkpll clkpll
    .areset(~RESET_N)
    .c0(clkpll_c0)
    ...
```

---

### `socfw validate`

```sh
socfw validate <file.yaml>
```

Validates any framework YAML file. The file type is detected automatically from the `kind:` field:

| Kind | Validates |
|---|---|
| `project` | project.yaml — modules, clocks, reset, bus, connections |
| `ip` | *.ip.yaml — ports, clocking, artifacts |
| `timing` | timing_config.yaml — clocks, false paths, IO delays |
| `board` | board.yaml — pins, resources |

```sh
socfw validate project.yaml
socfw validate ip/my_module.ip.yaml
socfw validate timing_config.yaml
```

---

### `socfw simulate`

```sh
socfw simulate <project.yaml> [--out DIR] [--no-vcd]
```

Builds the project and runs an iverilog simulation:

1. Generates `sim/tb_soc_top.sv` and `sim/files.f`
2. Compiles with `iverilog -g2012`
3. Runs with `vvp`
4. Saves waveform to `sim/wave.vcd` (disable with `--no-vcd`)

```sh
socfw simulate project.yaml --out build
# → [sim] build/sim/tb_soc_top.sv
# → [sim] build/sim/files.f
# → [vcd] build/sim/wave.vcd
```

The generated testbench:
- Drives the primary clock at the period from `timing_config.yaml`
- Asserts/releases reset (`RESET_N`) with the polarity from the board descriptor
- Runs for 1000 clock cycles then calls `$finish`
- Captures all signals with `$dumpvars`

If `iverilog` is not installed, `socfw simulate` exits 0 with a `SIM001 WARNING`.

**View waveform** (requires GTKWave or similar):
```sh
gtkwave build/sim/wave.vcd
```

---

### `socfw explain`

```sh
socfw explain clocks project.yaml
socfw explain address-map project.yaml
socfw explain irqs project.yaml
socfw explain bus project.yaml
```

Prints a human-readable explanation of a design aspect.

---

### `socfw doctor`

```sh
socfw doctor project.yaml
```

Prints the fully resolved project configuration — effective board, IP catalog, clock domains, etc.
Useful for understanding what the framework sees after loading all packs and descriptors.

---

### `socfw explain-schema`

```sh
socfw explain-schema project     # canonical project.yaml example
socfw explain-schema ip          # canonical ip.yaml example
socfw explain-schema timing      # canonical timing_config.yaml example
socfw explain-schema board       # canonical board.yaml example
socfw explain-schema list        # list all available schemas
```

---

## Quick-start example

```sh
socfw init my_vga --template pll --board qmtech_ep4ce55
cd my_vga
socfw validate project.yaml
socfw build project.yaml --out build
socfw simulate project.yaml --out build
```

## Project shape

```yaml
version: 2
kind: project

project:
  name: my_design
  mode: standalone
  board: qmtech_ep4ce55

registries:
  packs:
    - packs/builtin
  ip:
    - ip

modules:
  - instance: blink0
    type: blink_test
```

## Notes

- Boards are resolved through packs (`registries.packs`).
- IP descriptors are loaded from `registries.ip` paths or packs.
- `socfw build` always generates sim files — no extra flag needed.
- Vendor IP (`.qip`) is automatically excluded from `sim/files.f`.
