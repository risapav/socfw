# Changelog

## vga_test_05 HDMI fixes (2026-05-13)

### Symptom
- Monitor displayed video for: `ENABLE_DATA_ISLAND=0` (any audio), `ENABLE_DATA_ISLAND=1 ENABLE_AUDIO=0`.
- Monitor went to sleep for: `ENABLE_DATA_ISLAND=1 ENABLE_AUDIO=1` (data island + audio enabled).

### Fixed
- `terc4_encoder`: confirmed 2-cycle pipeline, aligning with `tmds_video_encoder` and
  `tmds_control_encoder` before `hdmi_channel_mux`.
- `hdmi_period_scheduler`: lookahead `packet_pop_o` at `ST_DATA_GUARD_LEAD` exit so that
  symbol 0 clears the TERC4 (2-cycle) + channel_mux (1-cycle) pipeline before the first
  `DATA_PAYLOAD` cycle appears on `ch*_o`. Total pops: 31 (was 32, symbol-0 was duplicated
  and symbol-31 was lost).
- `hdmi_tx_core`: unified `ENABLE_AUDIO_IF && ENABLE_AUDIO_INFOFRAME` gating — both
  parameters must be set to enable the audio infoframe path.

### Verification
- `tb_terc4_encoder`: reset output `TERC4(0x0)`, exact 2-cycle latency, all 16 LUT entries.
- `tb_hdmi_period_scheduler`: `packet_pop` count updated to 31; all 4 scenarios pass.
- `tb_hdmi_tx_core_32x10`: added `period_d2` + `di_ch*_d3` delay pipeline and `terc4_ref()`
  LUT to verify `ch*_o` payload content cycle-accurately during `DATA_PAYLOAD`.
- All testbenches: `$finish` on pass replaced with `$fatal(1)` on failure for CI-friendliness.
- `sim/Makefile`: `?=` variables, `LOGDIR` with per-TB `tee` logs, `regression`/`report` targets,
  `terc4_encoder` moved before `tx_core_32x10`; `bash -o pipefail` preserves vsim exit code through pipe.

### Simulation baseline complete (2026-05-13)

`make report` passes all 11 HDMI simulation scenarios:

- `tb_hdmi_bch_ecc` PASS
- `tb_terc4_encoder` PASS
- `tb_data_island_formatter` PASS
- `tb_hdmi_period_scheduler` PASS
- `tb_acr_packet_builder` PASS
- `tb_audio_sample_packet_builder` PASS
- `tb_hdmi_tx_core_32x10` PASS
- `tb_audio_acr_only` PASS (ACR=1 IF=0 SAMPLE=0)
- `tb_audio_if_only` PASS (ACR=0 IF=1 SAMPLE=0)
- `tb_audio_sample_only` PASS (ACR=0 IF=0 SAMPLE=1)
- `tb_audio_full` PASS (ACR=1 IF=1 SAMPLE=1)

Logs generated under `sim/logs/` (gitignored).
ACR layout verified MSB-first across `acr_packet_builder.sv`, `tb_acr_packet_builder.sv`,
and `docs/HDMI_PACKET_LAYOUT.md`.

### Remaining validation
- Hardware test matrix on AC608 / HDMI monitor; see `docs/TEST_MATRIX.md`.
  - `DATA=0 AUDIO=0` — baseline DVI
  - `DATA=1 AUDIO=0` — data island (GCP + AVI only)
  - `DATA=1 AUDIO=1` ACR only
  - `DATA=1 AUDIO=1` Audio InfoFrame only
  - `DATA=1 AUDIO=1` Audio Sample only
  - `DATA=1 AUDIO=1` ACR + InfoFrame
  - `DATA=1 AUDIO=1` ACR + Sample
  - `DATA=1 AUDIO=1` ACR + InfoFrame + Sample (full audio)

---

## 0.3.0 (in progress)

### IR unification
- `RtlModuleIR` removed — single unified `RtlTop` IR for all build paths
- `soc_top.sv.j2` template revived: `RtlEmitter.emit()` now renders via Jinja2 instead of Python string building
- Dead code removed: `RtlIRBuilder`, `emit_top()`, `RtlWire`, `RtlAssign`, `RtlConn`, `RtlModuleInstance`, `RtlIR`, backward-compat aliases

### Reset architecture
- `reset_driver: instance.port` — top-level field to derive `reset_n` from any module output
  (typical use: PLL locked signal → CDC synchronizer → `reset_n`)
- `modules[].reset: auto | null | "expr"` — per-module reset override:
  `auto` = framework default, `null` = no connection, expression = wired directly
- Circular dependency prevention: PLL can receive `reset: "~RESET_N"` to avoid deadlock
  where PLL is held in reset by its own locked signal

### Validation
- RST010: `reset_driver` not in `instance.port` format
- RST011: `reset_driver` references unknown instance
- RST012: `reset_driver` references unknown port
- RST013: `reset_driver` port is not an output
- RST014: `reset_driver` port width is not 1
- RST020: `reset:` override on module with no reset port (warning)

### `socfw validate` — all YAML kinds
- Previously only validated `project.yaml`; now detects `kind:` and dispatches to
  appropriate loader: `project`, `ip`, `timing`, `board`

### Debug: `socfw build --trace`
- Prints `RtlTop` IR to stderr after build: ports, signals, adapt_assigns, instances with all connections
- Trace goes to stderr; standard stdout output unchanged
- Useful for diagnosing incorrect wiring without reading generated SV

### Simulation subsystem
- `socfw build` always generates `sim/tb_soc_top.sv` and `sim/files.f`
- Testbench uses clock period from `timing_config.yaml`, reset polarity from board descriptor
- `socfw simulate project.yaml` — builds + runs iverilog + vvp, saves `sim/wave.vcd`
- `--no-vcd` flag to disable waveform capture
- Vendor IP (`.qip`) automatically excluded from `sim/files.f`
- `simulation:` artifacts in IP descriptors included in filelist
- Error codes: `SIM001` (iverilog not found), `SIM002` (compile failed), `SIM003` (runtime failed)

### Documentation
- `docs/architecture/00_overview.md` — updated data flow, RtlTop, reset architecture, simulation
- `docs/schema/project_v2.md` — `reset_driver`, `modules[].reset`, `connections` documented
- `docs/user/getting_started.md` — `--trace`, `simulate`, all CLI commands
- `docs/user/simulation.md` — new: full simulation guide
- `docs/errors/project_diagnostics.md` — RST010–RST020, CLK001–CLK003 added

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
