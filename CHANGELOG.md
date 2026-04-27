# Changelog

## 0.2.0 (in progress)

### RTL generation
- Module parameter overrides: `params:` in `project.yaml` are emitted as `#(.NAME(VALUE))` blocks
  in `soc_top.sv`. Supports `int`, `bool` (→ `0`/`1`), SV literals (e.g. `"4'b1010"`), identifiers.
- `reset_active` wire removed: the framework no longer emits an unused `reset_active` signal.
  Active-high resets are connected using inline `~reset_n` in the instance port map.
- Reset emission is conditional: `RESET_N`, `reset_n` are only emitted when at least one
  instantiated IP has a `reset.port` declared (RST001 warning otherwise).
- Module-to-module connections: new `connections:` section in `project.yaml` wires ports between
  instances without going through the bus fabric. Creates `w_{inst}_{port}` intermediate wires.

### SDC / timing
- `create_generated_clock` uses correct Quartus altpll pin paths:
  source = `inst|inclk[0]`, target = `inst|altpll_component|auto_generated|pll1|clk[N]`
- `io_default_clock` domain name is resolved to the SDC clock name via `primary_clocks`
- Per-port IO delay overrides: `timing.io_delays.overrides` entries emit individual
  `set_input_delay`/`set_output_delay` pairs after the default IO delays

### Validation
- RST001: warning when board reset is declared but no IP consumes it
- TIM201: warning when IO delay `max_ns` is set without a corresponding `min_ns`
- PIN001: error when two `features.use` entries claim the same physical pin
  (sub-signal filtering: `board:onboard.uart.rx` claims only the RX pin, not all UART pins)

### IP descriptor
- `provides.modules` and `provides.package` fields: declare sub-modules and SV packages
  compiled from this descriptor's artifacts

### Examples
- `blink_test_01`: updated to reset-aware RTL (`rst_ni` port, active-low)
- `blink_test_02`: updated port names to standard convention (`clk_i`, `rst_ni`, `leds_o`),
  added timing config with correct altpll SDC pin paths
- `uart_test_01`: new example with UART + loopback status module, module-to-module
  connections, sub-signal board feature selection, per-port IO delay overrides

### Bug fixes
- `uart_baud_gen.sv`: explicit `COUNT_WIDTH'(1)` casts eliminate 32→N truncation (Quartus W10230)
- Board port direction was hardcoded to `output` — now reads actual direction from board resource
- `_prune_subpaths` was defined but never called before pin ownership check

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
