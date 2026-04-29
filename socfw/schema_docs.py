from __future__ import annotations


SCHEMA_DOCS: dict[str, str] = {
    "project": """# project.yaml v2

Canonical shape:

version: 2
kind: project

project:
  name: my_project
  mode: standalone        # standalone | soc
  board: qmtech_ep4ce55
  board_file: optional/path/to/board.yaml   # optional absolute/relative path
  debug: false

timing:
  file: timing_config.yaml

registries:
  packs: []   # paths to pack directories (e.g. ../../packs/builtin)
  ip: []      # paths to IP registry directories
  cpu: []     # paths to CPU descriptor directories

# reset_driver: instance.port
#
# When set, the named module output drives reset_n instead of the default
# direct assign from the board reset pin.  Use together with a
# cdc_reset_synchronizer (or equivalent) whose rst_ni is connected to a
# PLL locked signal so that reset_n deasserts only after the clock is stable.
#
# Example:
#   reset_driver: rst_sync0.rst_no
#
# Rules:
#   - instance must exist in modules:
#   - port must be an output of width 1 in the IP descriptor
#   - the PLL driving the synchroniser must use  reset: "~RESET_N"
#     to avoid a combinational loop through its own locked output

clocks:
  primary:
    domain: sys_clk
    source: board:sys_clk
  generated:
    - domain: clk_pixel
      source:
        instance: clkpll
        output: c0
      frequency_hz: 65000000
      reset:
        sync_from: sys_clk
        sync_stages: 2

modules:
  - instance: clkpll
    type: clkpll
    clocks:
      inclk0:
        domain: sys_clk
        no_reset: true
    # reset: controls how the IP reset port is connected
    #   "auto" (default) — connect to global reset_n (or ~reset_n for active-high)
    #   null             — leave reset port unconnected
    #   "<expr>"         — use a literal SV expression, e.g. "~RESET_N"
    reset: "~RESET_N"   # PLL areset must not depend on its own locked output

  - instance: rst_sync0
    type: cdc_reset_synchronizer
    clocks:
      clk_i: clk_pixel
    reset: null          # rst_ni is the signal being synchronised, not a reset
    params:
      STAGES: 3

  - instance: my_module
    type: my_module_type
    params:
      SOME_PARAM: 42
    clocks:
      clk_i: clk_pixel
    bind:
      ports:
        output_port_o:
          target: board:onboard.leds
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
