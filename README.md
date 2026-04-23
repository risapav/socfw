# socfw

Config-driven SoC/FPGA framework for:
- Board abstraction
- Typed YAML config loading and validation
- Elaboration (address map, clock domains, IRQ plan, bus bridges)
- RTL / timing / software / docs emission
- Firmware-aware two-pass build flows
- Protocol bridge insertion (simple_bus → AXI-lite, extensible)

## Quick start

```sh
pip install -e .

socfw validate <project.yaml>
socfw build <project.yaml> --out build/gen
socfw build-fw <project.yaml> --out build/gen
socfw sim-smoke <project.yaml> --out build/gen
```

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
