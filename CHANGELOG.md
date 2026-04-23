# Changelog

## 0.1.0 (internal milestone)

### Architecture
- 7-layer SoC framework: YAML → model → validation → elaboration → IR → emit → report
- Typed config loading with Pydantic (project, board, IP, CPU, timing schemas)
- Plugin registry for bus planners, bridge planners, emitters, reports, validators

### Bus and bridges
- `simple_bus` protocol: synchronous, minimal latency bus with SystemVerilog interface
- `simple_bus_fabric`: configurable multi-slave bus with address decoding and error slave
- Bridge registry: protocol adapter plugin API
- `simple_bus → axi_lite` bridge with state machine RTL
- `wishbone` bridge planner stub (pattern for future RTL)

### SoC features
- CPU descriptor model with `irq_abi`, `bus_master`, default params, artifacts
- PicoRV32 CPU with `simple_bus` wrapper
- Two-pass firmware-aware build flow (pass1 → compile → hex → pass2 with RAM init)
- IRQ controller (`irq_ctrl`) with pending/enable/ack registers
- IRQ combiner fallback for systems without irq_ctrl
- Linker script generation with correct IRQ entry address placement
- ISR dispatch table runtime (`isr_init`, `isr_register`, `irq_handler`)

### Validation
- Address overlap (BUS003), missing bridge (BRG001), unknown CPU type (CPU001)
- Bad board binding reference (BRD002), fabric protocol mismatch
- Negative test fixtures with expected error codes

### Emitters
- RTL: `soc_top.sv` via Jinja2 template
- Timing: `soc_top.sdc`
- Board: `board.tcl` for Quartus Prime
- Software: `soc_map.h`, `sections.lds`
- Docs: markdown block diagram
- Register block emitter for auto-generated register interfaces
- Simulation filelist emitter

### Tooling
- `socfw` CLI: validate, build, build-fw, sim-smoke, explain, graph
- Iverilog smoke simulation runner
- Two-pass build flow with BIN→HEX conversion
- CI workflows (GitHub Actions): unit, integration, golden, nightly, release
