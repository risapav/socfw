Super. Ideme na:

# repo hardening plan + CI layout + golden test matrix + release-ready project skeleton

Toto je správny moment. Architektúra je už dosť silná, takže najväčšiu hodnotu teraz prinesie to, aby sa z návrhu stal:

* stabilný repozitár,
* spoľahlivo testovaný framework,
* reviewovateľný projekt,
* základ pre ďalší tímový vývoj.

Tu by som to uzavrel do 4 vrstiev:

1. **repo skeleton**
2. **CI/CD**
3. **test matrix**
4. **release/dev ergonomics**

---

# 1. Release-ready repo skeleton

Odporúčaná štruktúra:

```text
socfw/
  __init__.py

  build/
  builders/
  cli/
  config/
  core/
  elaborate/
  emit/
  ir/
  model/
  plugins/
    bootstrap.py
    registry.py
    bridge_api.py
    bridges/
      simple_to_axi.py
      simple_to_wishbone.py
    simple_bus/
      planner.py
  reports/
  tools/
  validate/
    rules/
  templates/

src/
  ip/
    bus/
      bus_if.sv
      axi_lite_if.sv
      wishbone_if.sv
      simple_bus_fabric.sv
      simple_bus_error_slave.sv
      simple_bus_to_axi_lite_bridge.sv
    irq/
      irq_combiner.sv

docs/
  architecture/
    00_overview.md
    01_config_model.md
    02_elaboration.md
    03_bus_and_bridges.md
    04_firmware_flow.md
    05_irq_model.md
  dev_notes/
    checkpoints.md
    picorv32_wrapper_checklist.md
  user/
    getting_started.md
    project_yaml.md
    ip_yaml.md
    cpu_yaml.md
    timing_yaml.md
    cli.md

tests/
  unit/
  integration/
  golden/
    fixtures/
    expected/

examples/
  blink_test_01/
  blink_test_02/
  soc_led_test/
  picorv32_soc/
  axi_bridge_soc/

scripts/
  run_smoke.sh
  run_golden.sh
  run_ci_local.sh

.github/
  workflows/
    ci.yml
    golden.yml
    release.yml

pyproject.toml
README.md
LICENSE
CHANGELOG.md
```

---

# 2. Repo pravidlá, ktoré by som zaviedol hneď

## Branch model

Odporúčam:

* `main`
* feature branches:

  * `bootstrap/minimal-e2e`
  * `soc/simple-bus-core`
  * `soc/irq-runtime`
  * `bridge/axi-lite`
  * `hardening/ci-golden`

## Commit štýl

Drž sa krátkych prefixov:

```text
init:
config:
model:
validate:
elaborate:
ir:
emit:
report:
fw:
sim:
bridge:
test:
docs:
ci:
```

To veľmi pomôže pri review.

---

# 3. README minimum

`README.md` by mal mať len to najdôležitejšie:

* čo framework robí
* čo generuje
* aký je build flow
* rýchly quickstart
* ktoré toolchainy sú voliteľné

Odporúčaný obsah:

```md
# socfw

Config-driven SoC/FPGA framework for:
- board abstraction
- typed YAML config loading
- validation
- elaboration
- RTL/timing/software/docs emission
- firmware-aware build flows
- protocol bridge insertion

## Quick start
socfw validate <project.yaml>
socfw build <project.yaml> --out build/gen
socfw build-fw <project.yaml> --out build/gen
socfw sim-smoke <project.yaml> --out build/gen

## Supported slices
- standalone blink
- generated clocks / PLL
- simple_bus SoC
- PicoRV32 firmware flow
- AXI-lite bridged peripheral
```

---

# 4. CI layout

Tu je praktický CI layout, ktorý dáva zmysel.

## `.github/workflows/ci.yml`

Jobs:

### job 1 — lint + unit

* python setup
* install package
* `pytest tests/unit`

### job 2 — integration

* `pytest tests/integration -m "not toolchain_required"`

### job 3 — golden text artifacts

* generate outputs
* compare against `tests/golden/expected`

### job 4 — optional firmware/sim

* len ak je toolchain k dispozícii
* alebo self-hosted
* `build-fw`
* `sim-smoke`

---

## odporúčaný `ci.yml` skeleton

```yaml
name: CI

on:
  push:
  pull_request:

jobs:
  unit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.11"
      - run: pip install -e .
      - run: pip install pytest
      - run: pytest tests/unit

  integration:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.11"
      - run: pip install -e .
      - run: pip install pytest
      - run: pytest tests/integration -k "not picorv32 and not sim"

  golden:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.11"
      - run: pip install -e .
      - run: pip install pytest
      - run: pytest tests/golden
```

---

# 5. Toolchain-gated jobs

Firmware a simulation testy by som nedával do povinného CI jobu, ak:

* nemáš garantovaný RISC-V GCC
* nemáš garantovaný `iverilog`

Preto odporúčam:

## marker strategy

```python
@pytest.mark.toolchain_required
@pytest.mark.sim_required
```

a potom:

* default CI ich skipne
* nightly / manual workflow ich pustí

---

## `.github/workflows/golden.yml`

Môže byť manual alebo nightly:

```yaml
name: Golden Extended

on:
  workflow_dispatch:
  schedule:
    - cron: "0 2 * * *"

jobs:
  extended:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.11"
      - run: pip install -e .
      - run: pip install pytest
      - run: sudo apt-get update
      - run: sudo apt-get install -y iverilog
      - run: pytest tests/integration -m "not toolchain_required or sim_required"
```

RISC-V GCC je často citlivejší, takže to môže byť buď:

* container,
* self-hosted runner,
* alebo manual workflow.

---

# 6. Golden test matrix

Tu je podľa mňa správne minimum.

## A. Standalone fixtures

### `blink_test_01`

Overuje:

* loader
* board binding
* top-level RTL
* board.tcl

### `blink_test_02`

Overuje:

* generated clocks
* timing emission
* PLL artifacts
* width adaptation

---

## B. SoC fixtures

### `soc_led_test`

Overuje:

* simple_bus
* RAM
* GPIO
* register block
* shell generation
* docs/software map

### `picorv32_soc`

Overuje:

* CPU descriptor
* firmware-aware build
* IRQ controller
* linker/header generation

### `axi_bridge_soc`

Overuje:

* bridge insertion
* AXI-lite interface generation
* bridge RTL emission

---

## C. Negative fixtures

Toto je veľmi dôležité.

### `bad_overlap_soc`

* dve periférie s rovnakým address range
* očakáva `BUS003`

### `bad_cpu_type`

* chýbajúci CPU descriptor
* očakáva `CPU001`

### `bad_bridge_missing`

* peripheral protocol = wishbone
* bridge plugin neregistrovaný
* očakáva `BRG001`

### `bad_board_ref`

* zlá board feature referencia
* očakáva `BRD001`

Negative fixtures často chytia regresie lepšie než happy path.

---

# 7. Golden comparison stratégia

Odporúčam dve úrovne:

## Level 1 — smoke golden

Len kontroluje:

* súbor existuje
* obsahuje kľúčové tokeny

Používaj na integration testy.

## Level 2 — exact golden snapshot

Porovnáva celý súbor:

* `soc_top.sv`
* `soc_top.sdc`
* `board.tcl`
* `soc_map.h`
* `build_report.md`

Používaj na stabilné fixtures.

---

## Odporúčaný helper

`tests/golden/test_golden_outputs.py`

```python
from pathlib import Path

from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline


def _read(p: Path) -> str:
    return p.read_text(encoding="utf-8")


def assert_same(generated: Path, expected: Path):
    assert generated.exists(), f"Missing generated file: {generated}"
    assert expected.exists(), f"Missing expected file: {expected}"
    assert _read(generated) == _read(expected)


def test_blink_test_01_golden(tmp_path):
    templates = "socfw/templates"
    fixture = Path("tests/golden/fixtures/blink_test_01/project.yaml")
    expected = Path("tests/golden/expected/blink_test_01")
    out_dir = tmp_path / "gen"

    pipeline = FullBuildPipeline(templates_dir=templates)
    result = pipeline.run(BuildRequest(project_file=str(fixture), out_dir=str(out_dir)))

    assert result.ok

    assert_same(out_dir / "rtl" / "soc_top.sv", expected / "rtl" / "soc_top.sv")
    assert_same(out_dir / "hal" / "board.tcl", expected / "hal" / "board.tcl")
```

---

# 8. Pytest markers

Do `pyproject.toml` doplň:

```toml
[tool.pytest.ini_options]
testpaths = ["tests"]
pythonpath = ["."]
markers = [
  "toolchain_required: requires external compiler toolchain",
  "sim_required: requires simulator",
  "golden: snapshot comparison tests",
]
```

To veľmi pomôže pri CI filtrovaní.

---

# 9. Local dev scripts

Tieto skripty sa veľmi oplatia.

## `scripts/run_smoke.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

pytest tests/unit
pytest tests/integration -k "not picorv32 and not sim"
```

## `scripts/run_golden.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

pytest tests/golden
```

## `scripts/run_ci_local.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

pytest tests/unit
pytest tests/integration
pytest tests/golden
```

---

# 10. Packaging hardening

Do `pyproject.toml` by som doplnil aspoň:

```toml
[build-system]
requires = ["setuptools>=68", "wheel"]
build-backend = "setuptools.build_meta"

[tool.setuptools.packages.find]
include = ["socfw*"]

[tool.setuptools.package-data]
socfw = ["templates/*.j2"]
```

Aby:

* `pip install -e .` fungovalo konzistentne
* templaty sa nestrácali

---

# 11. Docs hardening

Najdôležitejšie docs sú len 4:

## `docs/user/getting_started.md`

* ako spustiť validate/build/build-fw/sim-smoke

## `docs/user/project_yaml.md`

* čo znamená `project.yaml`

## `docs/architecture/03_bus_and_bridges.md`

* `simple_bus`
* bridge registry
* adapter planning

## `docs/architecture/04_firmware_flow.md`

* dvojfázový build
* linker script
* firmware.hex do RAM

Toto by som spravil hneď.

---

# 12. Release workflow

Ak chceš mať čistý release-ready základ, priprav si:

## `.github/workflows/release.yml`

* trigger na tag `v*`
* build wheel/sdist
* attach artifacts
* prípadne GitHub Release notes

Skeleton:

```yaml
name: Release

on:
  push:
    tags:
      - "v*"

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.11"
      - run: pip install build
      - run: python -m build
      - uses: actions/upload-artifact@v4
        with:
          name: dist
          path: dist/*
```

---

# 13. “Definition of done” pre hardening fázu

Ja by som to uzavrel takto:

## Hardening je hotový, keď:

* `pytest tests/unit` je green
* `pytest tests/integration` je green bez toolchain-only testov
* golden snapshoty pre stabilné fixtures sú green
* `pip install -e .` funguje
* `socfw build ...` funguje z čistého checkoutu
* README a getting started sú zrozumiteľné
* CI beží na PR

To už je veľmi solídny framework milestone.

---

# 14. Môj úprimný architektonický verdikt

Po všetkých krokoch, ktoré sme prešli, má návrh frameworku veľmi dobré vlastnosti:

* typed config pipeline
* oddelená elaboration vrstva
* IR medzi modelom a emitom
* plugin registry
* bus bridge architektúra
* firmware-aware build
* IRQ subsystem
* reporting
* simulation smoke path

To je už výrazne nad úrovňou pôvodného “template-driven generatora”.

Najväčšia hodnota je podľa mňa v tom, že:

* control plane je generovateľný,
* data plane je oddeliteľný,
* a interconnect vieš rozširovať bez big-bang prerábky.

---

# 15. Čo by som odporučil ako posledný ďalší krok

Teraz už by som nešiel do ďalšej architektúry. Teraz by som spravil:

👉 **jednu stabilizačnú implementačnú vetvu**
kde sa naozaj dorobí:

* repo skeleton
* golden fixtures
* CI
* README/docs
* prvý clean release milestone

To je podľa mňa najlepší ďalší krok k reálnemu používaniu.

Ak chceš, v ďalšej správe ti môžem dať úplne prakticky:

**presný implementačný backlog po súboroch a commitoch pre “hardening sprint 1”**.
