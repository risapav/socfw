# Architecture Overview

## Layer diagram

```
YAML config files
   ↓ loaders (Pydantic schemas)
Model objects (Board, System, IpDescriptor, CpuDescriptor, ...)
   ↓ validation (rules engine)
Elaborated design (address map, clock domains, IRQ plan, interconnect)
   ↓ IR builders
RtlTop (unified IR — ports, signals, instances, adapt_assigns)
   ↓ emitters (Jinja2 templates + direct emitters)
Output files (.sv, .sdc, .tcl, .h, .lds, .md, ...)
   ↓ reports
Reports (markdown, JSON, Graphviz)
```

## Plugin registry

All extension points go through `PluginRegistry`:

```python
reg.register_bus_planner(...)      # protocol-specific bus planning
reg.register_bridge_planner(...)   # cross-protocol bridge injection
reg.register_emitter(...)          # artifact emitters by family
reg.register_report(...)           # report generators
reg.register_validator(...)        # validation rules
```

The builtin registry is created via `create_builtin_registry(templates_dir)` in `bootstrap.py`.

## Key data flows

### RTL generation (native path)

```
SystemModel
  → RtlIrBuilder.build()
      _add_basic_clock_reset_nets()   → ports + reset_n signal
      _add_board_bound_ports()        → board-bound IO ports
      _build_connection_wires()       → w_{inst}_{port} signals for connections:
      _inject_reset_driver_wire()     → pre-register reset_driver output wire
      _add_project_module_instances() → RtlInstance per module
          per-module reset_override: auto | null | "expr"
      _apply_reset_driver()           → adapt_assign reset_n = w_{inst}_{port}
      _add_bridge_instances()         → bridge placeholder instances
  → RtlTop                            → ports, signals, adapt_assigns, instances
  → RtlEmitter.emit()
      renderer.render("soc_top.sv.j2", module=top)
  → build/rtl/soc_top.sv

  → SimTbEmitter.emit()
      renderer.render("tb_soc_top.sv.j2", module=top, clk_period_ns=..., ...)
  → build/sim/tb_soc_top.sv

  → SimFilelistEmitter.emit()
  → build/sim/files.f
```

### RtlTop IR

The unified intermediate representation for the RTL top-level:

```python
@dataclass
class RtlTop:
    module_name: str                       # "soc_top"
    ports: list[RtlPort]                   # direction, name, width
    signals: list[RtlSignal]               # name, width, kind="wire"
    adapt_assigns: list[RtlAdaptAssign]    # lhs = rhs
    instances: list[RtlInstance]           # module, instance, parameters, connections
```

`RtlInstance` uses named tuples:
- `parameters: tuple[RtlParameter, ...]` — `(name, value)` pairs → `#(.NAME(value))`
- `connections: tuple[RtlConnection, ...]` — `(port, expr)` pairs → `.port(expr)`

### Reset architecture

The framework supports two reset modes:

**Mode A — board reset direct** (default):
```
RESET_N → reset_n → all IP reset ports
```

**Mode B — PLL-locked reset** (`reset_driver:`):
```
RESET_N → clkpll.areset (via reset: "~RESET_N" on clkpll instance)
clkpll.locked → cdc_reset_synchronizer.rst_ni
cdc_reset_synchronizer.rst_no → reset_n → all other IP
```

Per-module reset override (`reset:` on module instance):
- `reset: auto` (default) — framework connects `reset_n` or `~reset_n` per IP descriptor
- `reset: null` — no reset connection (module excluded from reset)
- `reset: "~RESET_N"` — explicit expression wired directly

### Firmware two-pass

```
Pass 1: FullBuildPipeline.run()  → RTL + headers + linker script
FirmwareBuilder.build()          → ELF → BIN
Bin2HexRunner.run()              → HEX
Pass 2: FullBuildPipeline.run()  → RTL with patched RAM init_file
```

### Simulation

```
FullBuildPipeline.run()
  → SimTbEmitter     → build/sim/tb_soc_top.sv   (auto-generated testbench)
  → SimFilelistEmitter → build/sim/files.f        (iverilog filelist)

socfw simulate project.yaml
  → FullBuildPipeline.run()
  → SimRunner.run_iverilog()
      iverilog -g2012 -s tb_soc_top -f sim/files.f -o sim/sim.vvp
      vvp sim/sim.vvp
  → build/sim/wave.vcd                            (VCD waveform)
```

## Templates

All RTL and simulation output is generated via Jinja2 templates in `socfw/templates/`:

| Template | Output | Description |
|---|---|---|
| `soc_top.sv.j2` | `rtl/soc_top.sv` | Top-level RTL module |
| `tb_soc_top.sv.j2` | `sim/tb_soc_top.sv` | Simulation testbench |
| `soc_top.sdc.j2` | `timing/soc_top.sdc` | Timing constraints |

Templates receive the `sv_param` Jinja2 filter for rendering SystemVerilog parameter values:
- `bool` → `"1"` / `"0"`
- `int` → decimal string
- SV literal string (e.g. `"4'b0101"`) → passed through unchanged
- identifier string → passed through unchanged
- other string → double-quoted
