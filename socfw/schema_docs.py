from __future__ import annotations


SCHEMA_DOCS: dict[str, str] = {
    "project": """# project.yaml v2

Canonical shape:

version: 2
kind: project

project:
  name: my_project
  mode: standalone
  board: qmtech_ep4ce55
  board_file: optional/path/to/board.yaml
  debug: true

timing:
  file: timing_config.yaml

registries:
  packs: []
  ip: []
  cpu: []

clocks:
  primary:
    domain: sys_clk
    source: board:SYS_CLK
    frequency_hz: 50000000
  generated: []

modules:
  - instance: blink_test
    type: blink_test
    params: {}
    clocks: {}
    bind: {}
""",

    "timing": """# timing_config.yaml v2

Canonical shape:

version: 2
kind: timing

timing:
  clocks:
    - name: SYS_CLK
      port: SYS_CLK
      period_ns: 20.0
      reset:
        port: RESET_N
        active_low: true
        sync_stages: 2

  io_delays:
    auto: true
    clock: SYS_CLK
    default_input_max_ns: 3.0
    default_output_max_ns: 3.0

  false_paths:
    - from_port: RESET_N
      comment: Async reset
""",

    "ip": """# ip.yaml v2

Canonical shape:

version: 2
kind: ip

ip:
  name: blink_test
  module: blink_test
  category: standalone

origin:
  kind: source
  packaging: plain_rtl

integration:
  needs_bus: false
  instantiate_directly: true

clocking:
  primary_input_port: SYS_CLK
  outputs: []

artifacts:
  synthesis:
    - ../rtl/blink_test.sv
  simulation: []
  metadata: []
""",

    "board": """# board.yaml v2

Canonical shape:

version: 2
kind: board

board:
  id: qmtech_ep4ce55

fpga:
  family: cyclone_iv_e
  part: EP4CE55F23C8

system:
  clock:
    id: sys_clk
    top_name: SYS_CLK
    pin: PIN_x
    frequency_hz: 50000000
  reset:
    id: reset_n
    top_name: RESET_N
    pin: PIN_y
    active_low: true

resources:
  onboard:
    leds:
      kind: vector
      top_name: ONB_LEDS
      width: 6
      pins: []
""",
}


def available_schemas() -> list[str]:
    return sorted(SCHEMA_DOCS)


def get_schema_doc(name: str) -> str | None:
    return SCHEMA_DOCS.get(name)
