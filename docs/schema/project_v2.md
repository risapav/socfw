# Project Configuration Schema v2

Canonical YAML structure for `project.yaml`.

## Minimal example

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

## Full reference

```yaml
version: 2
kind: project

project:
  name: <string>            # design name (used in reports)
  mode: <string>            # standalone | soc
  board: <string>           # board ID resolved from packs
  board_file: <string>      # path to board YAML (optional, overrides board:)
  debug: <bool>             # enable debug output (default: false)

registries:
  ip: [<path>, ...]         # IP descriptor search paths
  packs: [<path>, ...]      # pack search paths
  cpu: [<path>, ...]        # CPU registry paths

features:
  use: [<string>, ...]      # board feature flags (e.g. board:onboard.uart)

clocks:
  primary:
    domain: <string>        # primary clock domain name (default: sys_clk)
  generated:
    - domain: <string>      # clock domain name for this generated clock
      source:
        instance: <string>  # module instance producing the clock
        output: <string>    # output port name on that instance
      frequency_hz: <int>   # informational; not used for SDC
      reset:
        sync_from: <string> # which clock domain to sync reset from
        sync_stages: <int>  # synchronizer chain length (default: 2)
        none: <bool>        # true = skip reset sync for this domain

reset_driver: <instance>.<port>
  # Optional. Names a module output port that drives reset_n instead of RESET_N.
  # Use when reset must be derived from a PLL lock signal or other logic.
  # Example: reset_driver: rst_sync0.rst_no

modules:
  - instance: <string>      # unique instance name in soc_top.sv
    type: <string>          # IP type — must match ip.name in a loaded descriptor
    reset: auto | null | <expr>
      # Controls how the framework connects the reset port for this instance.
      # auto   (default) — framework uses IP descriptor reset.port and active_high
      # null   — no reset connection; reset port left at default tie-off
      # <expr> — explicit expression, e.g. "~RESET_N" or "my_reset_n"
    params:                 # parameter overrides → emitted as #(.NAME(VALUE))
      <PARAM>: <value>      # int, bool (→ 0/1), SV literal, identifier string
    clocks:
      <port>: <domain>      # clock port → domain name
      # Extended form:
      <port>:
        domain: <string>
        no_reset: <bool>    # true = do not auto-connect reset on this clock
    bind:
      ports:
        <port>:
          target: <string>  # board: reference or instance.port
          top_name: <string> # override top-level port name
          width: <int>      # override port width
          adapt: zero | replicate | high_z
    bus:
      fabric: <string>      # bus fabric name
      base: <hex>           # peripheral base address
      size: <hex>           # address window size

connections:
  - from: <instance>.<port> # output port on source module
    to: <instance>.<port>   # input port on destination module
  # Creates a wire w_{from_instance}_{from_port} connecting the two ports.

buses:
  - name: <string>
    protocol: <string>      # simple_bus | axi_lite | wishbone
    addr_width: <int>
    data_width: <int>

timing:
  file: <path>              # path to timing_config.yaml

cpu:
  instance: <string>
  type: <string>
  fabric: <string>
  reset_vector: <hex>
  params: {}

ram:
  module: <string>
  base: <hex>
  size: <hex>
  data_width: <int>
  addr_width: <int>
  latency: <int>
  init_file: <path>
  image_format: <string>

firmware:
  enabled: <bool>
  src_dir: <path>
  out_dir: <path>
  linker_script: <path>
  elf_file: <path>
  bin_file: <path>
  hex_file: <path>
  tool_prefix: <string>
  cflags: [<string>, ...]
  ldflags: [<string>, ...]
```

---

## `reset_driver` — PLL-locked reset

Use when `reset_n` must come from a PLL lock signal rather than directly from `RESET_N`:

```yaml
reset_driver: rst_sync0.rst_no
```

**Effect in generated RTL:**
```systemverilog
wire w_rst_sync0_rst_no;
assign reset_n = w_rst_sync0_rst_no;
```

The named port (`rst_no` on instance `rst_sync0`) is automatically wired to `reset_n`.
No `assign reset_n = RESET_N` is emitted when `reset_driver:` is set.

**Typical pattern — PLL + CDC reset synchronizer:**

```yaml
reset_driver: rst_sync0.rst_no

modules:
  - instance: clkpll
    type: clkpll
    reset: "~RESET_N"          # PLL gets board reset directly (bypasses reset_n)
    clocks:
      inclk0: sys_clk

  - instance: rst_sync0
    type: cdc_reset_synchronizer
    reset: null                # synchronizer has no reset port
    params:
      STAGES: 3
    clocks:
      clk_i: pll_clk

connections:
  - from: clkpll.locked
    to: rst_sync0.rst_ni       # PLL locked → synchronizer input
```

**Generated RTL:**
```systemverilog
wire w_clkpll_locked;
wire w_rst_sync0_rst_no;
assign reset_n = w_rst_sync0_rst_no;

clkpll clkpll (.areset(~RESET_N), .locked(w_clkpll_locked), ...);
cdc_reset_synchronizer #(.STAGES(3)) rst_sync0 (
  .clk_i(clkpll_c0), .rst_ni(w_clkpll_locked), .rst_no(w_rst_sync0_rst_no));
```

---

## `modules[].reset` — per-module reset override

Controls how the framework connects the reset port of each module instance.

| Value | Behaviour |
|---|---|
| `auto` (default) | Uses IP descriptor `reset.port` and `active_high` to drive `reset_n` or `~reset_n` |
| `null` | No connection — reset port left at default tie-off (`1'b0`) |
| `"~RESET_N"` | Exact expression wired to the reset port |
| `"my_signal"` | Any valid SV expression |

Examples:

```yaml
modules:
  # Default: framework connects reset_n automatically
  - instance: uart0
    type: uart

  # PLL: reset from board pin directly (bypass reset_n)
  - instance: clkpll
    type: clkpll
    reset: "~RESET_N"

  # CDC synchronizer: no reset port at all
  - instance: rst_sync0
    type: cdc_reset_synchronizer
    reset: null
```

**Validation:**
- `RST020` — warning when `reset:` is set on a module whose IP descriptor has `reset.port: null`

---

## `connections` — module-to-module wiring

Connects an output port of one module to an input port of another without going through a board pin.

```yaml
connections:
  - from: clkpll.locked
    to: rst_sync0.rst_ni
  - from: pgen0.m_axis_data_o
    to: fifo0.s_axis_data_i
```

**Effect:** creates a wire `w_{from_instance}_{from_port}` in `soc_top.sv`:
```systemverilog
wire w_clkpll_locked;
// clkpll drives it, rst_sync0 receives it
```

Wire width is inferred from the source port's declared width in the IP descriptor.

---

## Deprecated aliases (v1 → v2)

| Deprecated key | Canonical key | Warning code |
|---|---|---|
| `timing.config` | `timing.file` | `PRJ_ALIAS001` |
| `paths.ip_plugins` | `registries.ip` | `PRJ_ALIAS002` |
| `board.type` | `project.board` | `PRJ_ALIAS003` |
| `board.file` | `project.board_file` | `PRJ_ALIAS004` |
| `design.name` | `project.name` | `PRJ_ALIAS005` |
| `design.mode` | `project.mode` | `PRJ_ALIAS006` |
| dict-style `modules` | list-style `modules` | `PRJ_ALIAS007` |
