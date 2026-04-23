# project.yaml Reference

## Top-level structure

```yaml
version: 2
kind: project

project:
  name: my_soc
  mode: soc
  board: qmtech_ep4ce55
  board_file: board.yaml
  output_dir: build/gen
  debug: false

registries:
  ip:
    - ip

features:
  use:
    - board:onboard.leds

clocks:
  primary:
    domain: sys_clk
    source: board:sys_clk
  generated: []

cpu:
  instance: cpu0
  type: picorv32_min
  fabric: main
  reset_vector: 0x00000000
  params:
    ENABLE_IRQ: true

ram:
  module: soc_ram
  base: 0x00000000
  size: 65536
  latency: registered
  init_file: ""
  image_format: hex

buses:
  - name: main
    protocol: simple_bus
    addr_width: 32
    data_width: 32

firmware:
  enabled: true
  src_dir: fw
  tool_prefix: riscv32-unknown-elf-

modules:
  - instance: gpio0
    type: gpio
    bus:
      fabric: main
      base: 0x40000000
      size: 0x1000
    clocks:
      SYS_CLK: sys_clk
    bind:
      ports:
        gpio_o:
          target: board:onboard.leds

artifacts:
  emit: [rtl, timing, board, software, docs]
```

## Sections

### `project`
- `name`: project identifier used in generated filenames
- `mode`: always `soc` for SoC projects
- `board`: board ID (must match board descriptor)
- `board_file`: path to board.yaml relative to project.yaml
- `output_dir`: default output directory (can be overridden via CLI `--out`)

### `registries.ip`
Directories scanned for `.ip.yaml` and `.cpu.yaml` files, relative to project.yaml.

### `features.use`
Board resources claimed by the project, e.g. `board:onboard.leds`.

### `clocks`
- `primary.domain`: name of the primary clock domain
- `primary.source`: board clock reference
- `generated`: list of generated clocks (PLLs)

### `cpu`
- `type`: CPU type name from IP catalog
- `fabric`: bus fabric the CPU masters
- `params`: override default CPU parameters

### `ram`
- `module`: RAM IP module name
- `base`: base address in hex
- `size`: size in bytes
- `init_file`: path to hex init file (patched by firmware build flow)

### `buses`
List of bus fabrics with protocol, addr_width, data_width.

### `modules`
List of peripheral instances:
- `type`: IP type name from catalog
- `bus.fabric` + `bus.base` + `bus.size`: bus attachment
- `clocks`: clock port → domain name mapping
- `bind.ports`: port → board resource binding
- `params`: override IP default parameters
