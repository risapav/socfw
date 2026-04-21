Áno. Tu je **presný plán pre branch `bootstrap/minimal-e2e`**: súbory, poradie implementácie a prvé fixture YAML.

## 1. Súbory v branche

```text
pyproject.toml

socfw/
  __init__.py

  core/
    diagnostics.py
    result.py

  config/
    common.py
    board_schema.py
    board_loader.py
    project_schema.py
    project_loader.py
    timing_schema.py
    timing_loader.py
    ip_schema.py
    ip_loader.py
    system_loader.py

  model/
    board.py
    project.py
    timing.py
    ip.py
    system.py

  validate/
    rules/
      base.py
      board_rules.py
      project_rules.py
      asset_rules.py

  elaborate/
    board_bindings.py
    clocks.py
    design.py
    planner.py

  ir/
    board.py
    timing.py
    rtl.py

  builders/
    board_ir_builder.py
    timing_ir_builder.py
    rtl_ir_builder.py

  emit/
    renderer.py
    rtl_emitter.py
    timing_emitter.py
    board_quartus_emitter.py
    files_tcl_emitter.py
    orchestrator.py

  reports/
    model.py
    builder.py
    json_emitter.py
    markdown_emitter.py
    graph_model.py
    graph_builder.py
    graphviz_emitter.py
    explain.py
    orchestrator.py

  plugins/
    registry.py
    bootstrap.py

  build/
    context.py
    manifest.py
    pipeline.py
    full_pipeline.py

  cli/
    main.py

  templates/
    soc_top.sv.j2
    soc_top.sdc.j2

tests/
  unit/
    test_board_loader.py
    test_project_loader.py
    test_timing_loader.py
    test_ip_loader.py
    test_validation.py

  integration/
    test_validate_blink01.py
    test_build_blink01.py
    test_build_blink02.py

  golden/
    fixtures/
      blink_test_01/
        board.yaml
        project.yaml
        ip/
          blink_test.ip.yaml
      blink_test_02/
        board.yaml
        project.yaml
        timing.yaml
        ip/
          blink_test.ip.yaml
          clkpll.ip.yaml
    expected/
      blink_test_01/
        rtl/soc_top.sv
        hal/board.tcl
        reports/build_report.md
      blink_test_02/
        rtl/soc_top.sv
        timing/soc_top.sdc
        reports/soc_graph.dot
```

## 2. Poradie implementácie

### Krok 1

Založ:

* `pyproject.toml`
* `core/*`
* `cli/main.py`
* `build/context.py`

A rozbehni príkaz:

```bash
socfw validate <project.yaml>
```

### Krok 2

Pridaj:

* `model/*`
* `config/*_schema.py`
* `config/*_loader.py`
* `config/system_loader.py`

Cieľ:

* `SystemLoader().load(...)` funguje pre `blink_test_01`

### Krok 3

Pridaj validation:

* `validate/rules/base.py`
* `board_rules.py`
* `project_rules.py`
* `asset_rules.py`

Cieľ:

* chyby sa vracajú cez `Diagnostic`, nie `print + exit`

### Krok 4

Pridaj elaboration:

* `elaborate/board_bindings.py`
* `elaborate/clocks.py`
* `elaborate/design.py`
* `elaborate/planner.py`

Cieľ:

* z `blink_test_01` vznikne resolved board binding pre LED
* z `blink_test_02` vznikne generated domain z PLL

### Krok 5

Pridaj IR a buildre:

* `ir/board.py`
* `ir/timing.py`
* `ir/rtl.py`
* `builders/*`

Cieľ:

* build pipeline vie vytvoriť `board_ir`, `timing_ir`, `rtl_ir`

### Krok 6

Pridaj emitre:

* `emit/renderer.py`
* `rtl_emitter.py`
* `timing_emitter.py`
* `board_quartus_emitter.py`
* `files_tcl_emitter.py`
* `emit/orchestrator.py`
* templaty `soc_top.sv.j2`, `soc_top.sdc.j2`

Cieľ:

* `socfw build` vyrobí prvé 4 artefakty

### Krok 7

Pridaj reporting:

* `reports/*`
* napojenie do `build/full_pipeline.py`

Cieľ:

* vznikne `build_report.json`, `build_report.md`, `soc_graph.dot`

### Krok 8

Pridaj testy:

* unit
* integration
* golden pre blink01
* golden pre blink02

## 3. Minimálny `pyproject.toml`

```toml
[project]
name = "socfw"
version = "0.1.0"
requires-python = ">=3.11"
dependencies = [
  "pydantic>=2.0",
  "pyyaml>=6.0",
  "jinja2>=3.1",
]

[project.scripts]
socfw = "socfw.cli.main:main"

[tool.pytest.ini_options]
testpaths = ["tests"]
pythonpath = ["."]
```

## 4. Prvé fixture YAML

### `tests/golden/fixtures/blink_test_01/board.yaml`

```yaml
version: 2
kind: board

board:
  id: qmtech_ep4ce55
  vendor: QMTech
  title: QMTech EP4CE55F23C8

fpga:
  family: "Cyclone IV E"
  part: EP4CE55F23C8

system:
  clock:
    id: sys_clk
    top_name: SYS_CLK
    pin: T2
    io_standard: "3.3-V LVTTL"
    frequency_hz: 50000000
    period_ns: 20.0

  reset:
    id: sys_reset_n
    top_name: RESET_N
    pin: W13
    io_standard: "3.3-V LVTTL"
    active_low: true
    weak_pull_up: true

resources:
  onboard:
    leds:
      kind: gpio_out
      top_name: ONB_LEDS
      direction: output
      width: 6
      io_standard: "3.3-V LVTTL"
      pins:
        5: A6
        4: B7
        3: A7
        2: B8
        1: A8
        0: E4
  connectors: {}
```

### `tests/golden/fixtures/blink_test_01/project.yaml`

```yaml
version: 2
kind: project

project:
  name: blink_test_01
  mode: standalone
  board: qmtech_ep4ce55
  board_file: tests/golden/fixtures/blink_test_01/board.yaml
  output_dir: build/gen
  debug: true

registries:
  ip:
    - tests/golden/fixtures/blink_test_01/ip

features:
  use:
    - board:onboard.leds

clocks:
  primary:
    domain: sys_clk
    source: board:sys_clk
  generated: []

modules:
  - instance: blink_test
    type: blink_test
    params:
      CLK_FREQ: 50000000
    clocks:
      SYS_CLK: sys_clk
    bind:
      ports:
        ONB_LEDS:
          target: board:onboard.leds

artifacts:
  emit: [rtl, timing, board, docs]
```

### `tests/golden/fixtures/blink_test_01/ip/blink_test.ip.yaml`

```yaml
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
  generate_registers: false
  instantiate_directly: true
  dependency_only: false

reset:
  port: null

clocking:
  primary_input_port: SYS_CLK
  additional_input_ports: []
  outputs: []

artifacts:
  synthesis:
    - rtl/blink_test.sv
  simulation: []
  metadata: []
```

## 5. Fixture pre PLL

### `tests/golden/fixtures/blink_test_02/board.yaml`

Použi rovnaký ako pre blink01, ale doplň PMOD role:

```yaml
version: 2
kind: board

board:
  id: qmtech_ep4ce55
  vendor: QMTech
  title: QMTech EP4CE55F23C8

fpga:
  family: "Cyclone IV E"
  part: EP4CE55F23C8

system:
  clock:
    id: sys_clk
    top_name: SYS_CLK
    pin: T2
    io_standard: "3.3-V LVTTL"
    frequency_hz: 50000000
    period_ns: 20.0

  reset:
    id: sys_reset_n
    top_name: RESET_N
    pin: W13
    io_standard: "3.3-V LVTTL"
    active_low: true
    weak_pull_up: true

resources:
  onboard:
    leds:
      kind: gpio_out
      top_name: ONB_LEDS
      direction: output
      width: 6
      io_standard: "3.3-V LVTTL"
      pins:
        5: A6
        4: B7
        3: A7
        2: B8
        1: A8
        0: E4

  connectors:
    pmod:
      J10:
        roles:
          led8:
            top_name: PMOD_J10
            direction: output
            width: 8
            io_standard: "3.3-V LVTTL"
            pins:
              7: H1
              6: H2
              5: F1
              4: F2
              3: E1
              2: D2
              1: C1
              0: C2

      J11:
        roles:
          led8:
            top_name: PMOD_J11
            direction: output
            width: 8
            io_standard: "3.3-V LVTTL"
            pins:
              7: R1
              6: R2
              5: P1
              4: P2
              3: N1
              2: N2
              1: M1
              0: M2
```

### `tests/golden/fixtures/blink_test_02/project.yaml`

```yaml
version: 2
kind: project

project:
  name: blink_test_02
  mode: standalone
  board: qmtech_ep4ce55
  board_file: tests/golden/fixtures/blink_test_02/board.yaml
  output_dir: build/gen
  debug: true

registries:
  ip:
    - tests/golden/fixtures/blink_test_02/ip

features:
  use:
    - board:onboard.leds
    - board:connector.pmod.J10.role.led8
    - board:connector.pmod.J11.role.led8

clocks:
  primary:
    domain: sys_clk
    source: board:sys_clk

  generated:
    - domain: clk_100mhz
      source:
        instance: clkpll
        output: c0
      frequency_hz: 100000000
      reset:
        sync_from: sys_clk
        sync_stages: 2

modules:
  - instance: clkpll
    type: clkpll
    clocks:
      inclk0: sys_clk

  - instance: blink_01
    type: blink_test
    params:
      CLK_FREQ: 100000000
    clocks:
      SYS_CLK: clk_100mhz
    bind:
      ports:
        ONB_LEDS:
          target: board:onboard.leds

  - instance: blink_02
    type: blink_test
    params:
      CLK_FREQ: 100000000
    clocks:
      SYS_CLK: clk_100mhz
    bind:
      ports:
        ONB_LEDS:
          target: board:connector.pmod.J10.role.led8
          top_name: PMOD_J10
          width: 8
          adapt: replicate

  - instance: blink_03
    type: blink_test
    params:
      CLK_FREQ: 50000000
    clocks:
      SYS_CLK: sys_clk
    bind:
      ports:
        ONB_LEDS:
          target: board:connector.pmod.J11.role.led8
          top_name: PMOD_J11
          width: 8
          adapt: zero

timing:
  file: timing.yaml

artifacts:
  emit: [rtl, timing, board, docs]
```

### `tests/golden/fixtures/blink_test_02/timing.yaml`

```yaml
version: 2
kind: timing

timing:
  derive_uncertainty: true

  clocks:
    - name: sys_clk
      source: SYS_CLK
      period_ns: 20.0
      uncertainty_ns: 0.1
      reset:
        source: RESET_N
        active_low: true
        sync_stages: 2

  generated_clocks:
    - name: clk_100mhz
      source:
        instance: clkpll
        output: c0
      multiply_by: 2
      divide_by: 1
      reset_sync_from: sys_clk
      reset_sync_stages: 2

  clock_groups: []

  io_delays:
    auto: true
    default_clock: sys_clk
    default_input_max_ns: 2.5
    default_output_max_ns: 2.5
    overrides: []

  false_paths: []
```

### `tests/golden/fixtures/blink_test_02/ip/blink_test.ip.yaml`

Rovnaký ako pre blink01.

### `tests/golden/fixtures/blink_test_02/ip/clkpll.ip.yaml`

```yaml
version: 2
kind: ip

ip:
  name: clkpll
  module: clkpll
  category: standalone

origin:
  kind: vendor_generated
  tool: quartus
  packaging: qip

integration:
  needs_bus: false
  generate_registers: false
  instantiate_directly: true
  dependency_only: false

reset:
  port: areset
  active_high: true
  bypass_sync: true

clocking:
  primary_input_port: inclk0
  additional_input_ports: []
  outputs:
    - port: c0
      kind: generated_clock
      default_domain: clk_100mhz
    - port: locked
      kind: status
      signal_name: pll_locked

artifacts:
  synthesis:
    - quartus_ip/clkpll.qip
  simulation:
    - quartus_ip/clkpll.v
    - quartus_ip/clkpll_bb.v
  metadata: []
```

## 6. Prvé golden očakávania

Na začiatok by som neporovnával celé súbory po bajte. Najprv daj “smoke golden checks”:

### `tests/integration/test_build_blink01.py`

* existuje `rtl/soc_top.sv`
* obsahuje `module soc_top`
* obsahuje `blink_test`
* existuje `hal/board.tcl`
* obsahuje `ONB_LEDS`
* existuje `reports/build_report.json`

### `tests/integration/test_build_blink02.py`

* `soc_top.sv` obsahuje `clkpll`
* `soc_top.sv` obsahuje `blink_01`, `blink_02`, `blink_03`
* `soc_top.sdc` obsahuje `create_generated_clock`
* graph `.dot` obsahuje uzol `clkpll` alebo fabric/clock edge podľa implementácie

Až potom sprav plné snapshot porovnania.

## 7. CLI milestone

Keď bude branch hotový, tieto príkazy musia fungovať:

```bash
socfw validate tests/golden/fixtures/blink_test_01/project.yaml
socfw build tests/golden/fixtures/blink_test_01/project.yaml --out build/blink01
socfw build tests/golden/fixtures/blink_test_02/project.yaml --out build/blink02
socfw explain clocks tests/golden/fixtures/blink_test_02/project.yaml
socfw graph tests/golden/fixtures/blink_test_02/project.yaml --out build/blink02
```

## 8. Definition of done

Branch `bootstrap/minimal-e2e` je hotový, keď:

* `validate` prejde na blink01 a blink02
* `build` vyrobí:

  * `rtl/soc_top.sv`
  * `timing/soc_top.sdc` pre blink02
  * `hal/board.tcl`
  * `files.tcl`
  * `reports/build_report.json`
  * `reports/build_report.md`
  * `reports/soc_graph.dot`
* integration testy sú zelené
* žiadny board pin nie je hardcoded v emitri
* žiadny legacy SoC context nie je potrebný pre tieto 2 projekty

## 9. Moje odporúčané commit správy

```text
init: create socfw repo skeleton and CLI
config: add typed schemas and YAML loaders
model: add canonical board/project/timing/ip/system models
validate: add core validation rules
elaborate: resolve board bindings and clock domains
ir: add board timing and rtl intermediate representations
emit: add rtl timing board and files emitters
report: add json markdown and graphviz reporting
test: add blink_test_01 integration fixture
test: add blink_test_02 pll fixture and timing coverage
```

## 10. Čo by som spravil hneď po tomto branche

Keď bude tento branch zelený, ďalší branch by mal byť:

**`soc/simple-bus-core`**

Tam už pridáš:

* `buses:` do project YAML
* bus planner
* CPU/RAM/peripheral address map
* software/docs IR
* register blocks

To už bude prirodzené pokračovanie na stabilnom základe.

Ak chceš, ďalší krok ti môžem spraviť úplne prakticky ako **“copy-paste ready” minimálny set konkrétnych Python súborov pre branch `bootstrap/minimal-e2e`**, aby sa dalo rovno začať implementovať.
