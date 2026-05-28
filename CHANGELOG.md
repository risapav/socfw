# socfw

Config-driven SoC/FPGA framework for:
- Board abstraction
- Typed YAML config loading and validation
- Elaboration (address map, clock domains, IRQ plan, bus bridges)
- RTL / timing / software / docs emission
- Firmware-aware two-pass build flows
- Protocol bridge insertion (simple_bus → AXI-lite, extensible)

## Quickstart

Validate a project:

```bash
socfw validate tests/golden/fixtures/blink_converged/project.yaml
```

Build a project:

```bash
socfw build tests/golden/fixtures/blink_converged/project.yaml --out build/blink_converged
```

Reference new-flow fixtures:

- `tests/golden/fixtures/blink_converged`
- `tests/golden/fixtures/pll_converged`
- `tests/golden/fixtures/vendor_pll_soc`
- `tests/golden/fixtures/vendor_sdram_soc`

Legacy scripts are kept only as migration fallback.

## Supported configurations

| Fixture              | What it demonstrates                          |
|----------------------|-----------------------------------------------|
| `blink_test_01`      | Standalone RTL + board TCL                    |
| `blink_test_02`      | Generated clocks, PLL, timing, width adapters |
| `soc_led_test`       | simple_bus SoC, RAM, GPIO, register map       |
| `picorv32_soc`       | PicoRV32 CPU, firmware flow, IRQ controller   |
| `axi_bridge_soc`     | AXI-lite bridged peripheral                   |

## Optional toolchains

| Feature          | Requirement                          |
|------------------|--------------------------------------|
| Firmware compile | `riscv32-unknown-elf-gcc`            |
| RTL simulation   | `iverilog` + `vvp`                   |
| FPGA synthesis   | Quartus Prime (for board TCL output) |

## Running tests

```sh
# Unit + integration (no toolchain)
./scripts/run_smoke.sh

# Golden snapshot comparison
./scripts/run_golden.sh

# Full CI suite
./scripts/run_ci_local.sh
```

## Architecture overview

```
YAML (project / board / ip / cpu)
  → loader → model
  → validation (rules engine)
  → elaboration (address map, clocks, bus plan, bridge injection)
  → IR (RtlModuleIR, SoftwareIR, TimingIR, DocsIR, ...)
  → emitters (Jinja2 templates → .sv / .sdc / .tcl / .h / .md)
  → reports (graph, markdown, JSON)
```

## Protocol bridge architecture

Core fabric: `simple_bus`
Peripherals: `simple_bus`, `axi_lite`, `wishbone` (via bridge plugins)

Bridge plugins are registered in the plugin registry and injected automatically
by the bus planner when a protocol mismatch is detected.

## Schema and docs

```bash
socfw schema export --out build/schema
socfw docs export --out build/docs
```

- `schema export` — JSON Schema for all config types (board, project, ip, cpu, timing); enables IDE autocomplete via YAML extension
- `docs export` — human-readable Markdown reference tables + examples catalog from test fixtures

## Project scaffolding

List templates:
```bash
socfw list-templates
```

List boards:
```bash
socfw list-boards
```

Initialize a new project:
```bash
socfw init my_soc --template picorv32-soc --board qmtech_ep4ce55
```

## New `socfw` flow

The converged flow uses:

```bash
socfw validate <project.yaml>
socfw build <project.yaml> --out build
```

Reference fixtures:

- `tests/golden/fixtures/blink_converged`
- `tests/golden/fixtures/pll_converged`
- `tests/golden/fixtures/vendor_pll_soc`
- `tests/golden/fixtures/vendor_sdram_soc`

Legacy scripts are kept only for migration fallback.

## Legacy status

The legacy build flow is frozen and kept only as a migration fallback.

New projects should use:

```bash
socfw init <project_dir> --template blink
```

## Bugfixes

### files_tcl_emitter: absolute paths for shared/pack RTL replaced with relative (2026-05-28)

**Problem:** `FilesTclEmitter` and `QuartusFilesEmitter` emitted absolute host paths for any
RTL file located outside the project directory. Shared framework modules (`rtl/axi/`,
`rtl/axil/`, `rtl/cdc/`, etc.) and pack vendor files appeared as:

```tcl
set_global_assignment -name SYSTEMVERILOG_FILE "/home/palo/Projekty/socfw/rtl/axi/axi_pkg.sv"
```

This made generated `files.tcl` non-portable: the project could not be opened on another
machine or at a different clone path.

**Root cause:** `ip_loader.py` resolves artifact paths to absolute at load time. The emitter
used `Path.relative_to(project_dir)` to convert back to relative paths, but this method
raises `ValueError` when the file is not under the base directory. The fallback was
`str(abs_p)` — the full absolute path.

**Fix (`socfw/emit/files_tcl_emitter.py`):** Replace `Path.relative_to()` + fallback with
`os.path.relpath(abs_p, project_dir)`. Unlike `relative_to`, `os.path.relpath` handles
cross-directory traversal and produces `../../`-prefixed paths for files outside the project.

Result:

```tcl
# before
set_global_assignment -name SYSTEMVERILOG_FILE "/home/palo/Projekty/socfw/rtl/axi/axi_pkg.sv"

# after
set_global_assignment -name SYSTEMVERILOG_FILE "../../rtl/axi/axi_pkg.sv"
```

Quartus resolves all `set_global_assignment` paths relative to the `.qpf` project file
(in the project root), so `../../rtl/axi/axi_pkg.sv` resolves correctly on any machine
where the repository is cloned to the same relative structure.

Applied to both `FilesTclEmitter` (legacy flow) and `QuartusFilesEmitter` (new pipeline).
Golden snapshots for `vendor_pll_soc` and `vendor_sdram_soc` updated accordingly.

### board_tcl_emitter: duplicate pin assignments + IO_STANDARD wildcard (2026-05-26)

**Problem 1 — duplicate `set_location_assignment` for bus pins**

When a project used both `features.use: [board:onboard.eth]` (whole resource group) and
explicit bind targets such as `board:onboard.eth.rxd`, the emitter added the sub-path to
`selected.paths` even though the parent already covered it. `collect_pin_ownership` then
processed each bus bit twice, producing duplicate TCL assignments.

Fix: `_emit_selected_resources` now skips a bind target path when any ancestor path is
already in `selected.paths` (`path.startswith(p + ".")`).

**Problem 2 — `IO_STANDARD` missing `[*]` wildcard for bus signals**

`set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to ETH_RXD` is silently
accepted by Quartus but does not reliably propagate to individual bus bits.
The correct form is `ETH_RXD[*]`.

Fix: `_emit_pin_uses` now appends `[*]` to `top_name` when emitting IO_STANDARD for
a vector signal.

Both fixes are covered by new unit tests in `tests/unit/test_board_tcl_emitter.py`.

### board.yaml qmtech_ep4ce55: GTX_CLK / TX_CLK directions swapped (2026-05-26)

`gtx_clk` and `tx_clk` had their `direction` fields reversed relative to the hardware:

| Signal     | Correct direction | Pin  | Description                        |
|------------|-------------------|------|------------------------------------|
| `gtx_clk`  | output            | U22  | FPGA drives 125 MHz reference to PHY |
| `tx_clk`   | input             | AB20 | PHY returns 25 MHz TX clock to FPGA  |

The bug caused Quartus to synthesise the top-level wrapper with the wrong I/O directions,
making Ethernet TX non-functional at hardware level.

## Release status

Current cutover target:

```text
v1.0.0-cutover
```

See:

- `docs/releases/v1.0.0-cutover.md`
- `docs/dev_notes/release_candidate_checklist.md`
