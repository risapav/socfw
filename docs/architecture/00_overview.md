# Architecture Overview

## Layer diagram

```
YAML config files
   ↓ loaders (Pydantic schemas)
Model objects (Board, System, IpDescriptor, CpuDescriptor, ...)
   ↓ validation (rules engine)
Elaborated design (address map, clock domains, IRQ plan, interconnect)
   ↓ IR builders
Intermediate Representations (RtlModuleIR, SoftwareIR, TimingIR, DocsIR, ...)
   ↓ emitters (Jinja2 templates)
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

### RTL generation

```
SystemModel
  → Elaborator.elaborate()
    → BoardBindingResolver  → port_bindings
    → ClockResolver         → clock_domains
    → SimpleBusPlanner      → interconnect (fabrics + bridges)
    → AddressMapBuilder     → peripheral_blocks
    → IrqPlanBuilder        → irq_plan
  → RtlIRBuilder.build()    → RtlModuleIR
  → RtlEmitter.emit()       → soc_top.sv
```

### Firmware two-pass

```
Pass 1: FullBuildPipeline.run()  → RTL + headers + linker script
FirmwareBuilder.build()          → ELF → BIN
Bin2HexRunner.run()              → HEX
Pass 2: FullBuildPipeline.run()  → RTL with patched RAM init_file
```
