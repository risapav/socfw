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
  name: clkpll
  module: clkpll
  category: clocking

origin:
  kind: generated
  packaging: quartus_ip

integration:
  needs_bus: false
  generate_registers: false
  instantiate_directly: true
  dependency_only: false

reset:
  port: areset
  active_high: true

clocking:
  primary_input_port: inclk0
  additional_input_ports: []
  outputs:
    - name: c0
      domain_hint: clk_100mhz
      frequency_hz: 100000000

ports:
  - name: inclk0
    direction: input
    width: 1
  - name: areset
    direction: input
    width: 1
  - name: c0
    direction: output
    width: 1

artifacts:
  synthesis:
    - clkpll.qip
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
