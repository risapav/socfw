Áno. Tu je **presný implementačný backlog po súboroch a commitoch pre “hardening sprint 1”**.

Cieľ sprintu:

* dostať repo do stabilného stavu,
* zafixovať základné fixtures,
* zapnúť CI,
* mať prvý “releaseable internal milestone”.

---

# 1. Sprint cieľ

Na konci sprintu má platiť:

* `pip install -e .` funguje
* `socfw validate ...` funguje
* `socfw build ...` funguje pre stable fixtures
* `pytest tests/unit` je green
* `pytest tests/integration` je green pre non-toolchain slice
* `pytest tests/golden` je green pre stabilné snapshoty
* CI beží na PR
* README + getting started sú hotové

---

# 2. Odporúčaný rozsah sprintu

Do sprintu by som zahrnul len tieto fixtures:

## stable

* `blink_test_01`
* `blink_test_02`
* `soc_led_test`

## optional / gated

* `picorv32_soc`
* `axi_bridge_soc`

Dôvod:

* firmware/toolchain/sim fixtures sú super, ale nech neblokujú základné CI

---

# 3. Commit plán

Odporúčam 10 commitov.

---

## Commit 1

### `init: finalize package skeleton and editable install`

### súbory

* `pyproject.toml`
* `socfw/__init__.py`
* `README.md`
* `.gitignore`

### úlohy

* doplniť `build-system`
* doplniť `setuptools.package-data` pre templates
* ignorovať:

  * `build/`
  * `.pytest_cache/`
  * `dist/`
  * `*.egg-info/`
  * `__pycache__/`

### `.gitignore`

```gitignore
build/
dist/
*.egg-info/
.pytest_cache/
__pycache__/
*.pyc
.venv/
```

---

## Commit 2

### `test: stabilize unit tests for loaders and validators`

### súbory

* `tests/unit/test_board_loader.py`
* `tests/unit/test_project_loader.py`
* `tests/unit/test_timing_loader.py`
* `tests/unit/test_ip_loader.py`
* `tests/unit/test_validation.py`

### úlohy

* pokryť:

  * valid board
  * valid project
  * valid timing
  * valid ip
  * unknown IP
  * bad board ref
  * overlap error

### minimum test cases

* `BoardLoader().load()` success
* `ProjectLoader().load()` success
* `IpLoader().load_catalog()` success
* `DuplicateAddressRegionRule`
* `UnknownCpuTypeRule`
* `MissingBridgeRule`

---

## Commit 3

### `test: add stable integration fixtures for blink and simple soc`

### súbory

* `tests/integration/test_validate_blink01.py`
* `tests/integration/test_build_blink01.py`
* `tests/integration/test_build_blink02.py`
* `tests/integration/test_build_soc_led.py`

### úlohy

* iba smoke assertions:

  * file exists
  * contains key token

### odporúčané assertions

#### blink01

* `soc_top.sv` exists
* contains `module soc_top`
* contains `blink_test`

#### blink02

* `soc_top.sdc` exists
* contains `create_generated_clock`
* contains `clkpll`

#### soc_led_test

* `soc_map.h` exists
* contains `GPIO0_VALUE_REG`
* `soc_map.md` exists
* contains `gpio0`

---

## Commit 4

### `golden: lock stable snapshots for standalone and simple soc`

### súbory

* `tests/golden/fixtures/blink_test_01/...`
* `tests/golden/fixtures/blink_test_02/...`
* `tests/golden/fixtures/soc_led_test/...`
* `tests/golden/expected/...`
* `tests/golden/test_golden_outputs.py`

### úlohy

* snapshotovať len stabilné artefakty:

  * `rtl/soc_top.sv`
  * `hal/board.tcl`
  * `timing/soc_top.sdc`
  * `sw/soc_map.h`
  * `docs/soc_map.md`
  * `reports/build_report.md`

### odporúčanie

Nezamykaj zatiaľ JSON report snapshot po bajtoch, ak ešte meníš štruktúru reportu.

---

## Commit 5

### `docs: add quickstart and architecture overview`

### súbory

* `README.md`
* `docs/user/getting_started.md`
* `docs/architecture/00_overview.md`
* `docs/architecture/03_bus_and_bridges.md`
* `docs/architecture/04_firmware_flow.md`

### úlohy

* quickstart:

  * validate
  * build
  * build-fw
  * sim-smoke
* overview:

  * YAML → model → validate → elaborate → IR → emit → report
* bus docs:

  * simple_bus
  * bridges
  * bridge registry
* firmware docs:

  * two-pass flow
  * sections.lds
  * firmware.hex → RAM

---

## Commit 6

### `ci: add unit integration and golden workflows`

### súbory

* `.github/workflows/ci.yml`
* `.github/workflows/golden.yml`

### úlohy

* CI:

  * install
  * run unit
  * run integration without toolchain-gated tests
  * run stable golden
* nightly/manual:

  * extended tests

### minimum `ci.yml`

* Python 3.11
* `pip install -e .`
* `pip install pytest`

---

## Commit 7

### `test: add pytest markers and toolchain-gated tests`

### súbory

* `pyproject.toml`
* `tests/integration/test_build_picorv32_fw.py`
* `tests/integration/test_sim_picorv32_smoke.py`
* `tests/integration/test_build_axi_bridge_soc.py`

### úlohy

* doplniť markers:

  * `toolchain_required`
  * `sim_required`
  * `golden`
* gated testy nech používajú `skipif`

---

## Commit 8

### `scripts: add local smoke and golden runners`

### súbory

* `scripts/run_smoke.sh`
* `scripts/run_golden.sh`
* `scripts/run_ci_local.sh`

### obsah

#### `scripts/run_smoke.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
pytest tests/unit
pytest tests/integration -k "not picorv32 and not sim"
```

#### `scripts/run_golden.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
pytest tests/golden
```

#### `scripts/run_ci_local.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
pytest tests/unit
pytest tests/integration
pytest tests/golden
```

---

## Commit 9

### `report: stabilize markdown report and explain output`

### súbory

* `socfw/reports/markdown_emitter.py`
* `socfw/reports/builder.py`
* `socfw/reports/explain.py`
* `socfw/cli/main.py`

### úlohy

* zafixovať poradie sekcií
* zafixovať poradie clock domains / address map / bus endpoints
* nech je markdown report stabilný pre golden tests
* doplniť `explain cpu-irq`, ak ešte nie je

### dôležité

Toto je kľúčové pre stabilné golden snapshoty.

---

## Commit 10

### `release: add changelog license and release workflow`

### súbory

* `CHANGELOG.md`
* `LICENSE`
* `.github/workflows/release.yml`

### úlohy

* jednoduchý changelog
* MIT/BSD/Apache podľa preferencie
* tag-based build workflow

---

# 4. Backlog po súboroch

Tu je backlog zoskupený priamo po adresároch.

---

## koreň repa

### `pyproject.toml`

Doplniť:

* build-system
* setuptools package-data
* pytest markers

### `README.md`

Doplniť:

* quickstart
* supported slices
* command list

### `CHANGELOG.md`

Prvá verzia:

```md
# Changelog

## 0.1.0
- bootstrap/minimal-e2e
- simple_bus SoC slice
- IRQ controller
- firmware-aware build
- AXI-lite bridge planning
```

---

## `docs/user/`

### `getting_started.md`

Obsah:

* inštalácia
* prvý build
* fixtures
* kde nájdeš artefakty

### `project_yaml.md`

Sekcie:

* `project`
* `registries`
* `features`
* `clocks`
* `cpu`
* `ram`
* `buses`
* `modules`
* `firmware`

### `ip_yaml.md`

Sekcie:

* `origin`
* `integration`
* `clocking`
* `bus_interfaces`
* `registers`
* `irqs`
* `shell`

### `cpu_yaml.md`

Sekcie:

* descriptor model
* `irq_abi`
* `bus_master`
* default params

### `cli.md`

Príkazy:

* `validate`
* `build`
* `build-fw`
* `graph`
* `sim-smoke`
* `explain`

---

## `docs/architecture/`

### `00_overview.md`

Jedna high-level schéma:

* config loaders
* validators
* elaborator
* IR builders
* emitters
* reports

### `03_bus_and_bridges.md`

Popíš:

* `simple_bus`
* interface instances
* fabrics
* bridge registry
* protocol adaptation

### `04_firmware_flow.md`

Popíš:

* pass 1
* linker/header generation
* firmware build
* bin→hex
* pass 2

### `05_irq_model.md`

Popíš:

* peripheral IRQs
* IRQ controller
* CPU IRQ ABI
* ISR runtime

---

## `tests/unit/`

Treba mať minimálne:

### `test_board_loader.py`

* valid scalar/vector resources
* invalid duplicate top names

### `test_project_loader.py`

* generated clocks
* bus fabric
* cpu instance

### `test_ip_loader.py`

* bus_interfaces
* shell metadata
* registers
* irqs

### `test_validation.py`

* missing bridge
* unknown cpu
* bad board ref
* overlap

---

## `tests/integration/`

### stable

* `test_build_blink01.py`
* `test_build_blink02.py`
* `test_build_soc_led.py`

### gated

* `test_build_picorv32_fw.py`
* `test_sim_picorv32_smoke.py`
* `test_build_axi_bridge_soc.py`

---

## `tests/golden/`

### stable expected

* `blink_test_01`
* `blink_test_02`
* `soc_led_test`

### optional later

* `picorv32_soc`
* `axi_bridge_soc`

Neuzamykal by som firmware-heavy fixtures do exact golden snapshotov hneď v sprint 1.

---

# 5. Test matrix

Tu je praktická matica.

| Fixture            | validate | build | golden |  fw |      sim |
| ------------------ | -------: | ----: | -----: | --: | -------: |
| blink_test_01      |      yes |   yes |    yes |  no |       no |
| blink_test_02      |      yes |   yes |    yes |  no |       no |
| soc_led_test       |      yes |   yes |    yes |  no | optional |
| picorv32_soc       |      yes |   yes |  later | yes |      yes |
| axi_bridge_soc     |      yes |   yes |  later | yes | optional |
| bad_overlap_soc    | yes fail |   n/a |     no |  no |       no |
| bad_cpu_type       | yes fail |   n/a |     no |  no |       no |
| bad_bridge_missing | yes fail |   n/a |     no |  no |       no |

---

# 6. CI rozdelenie

Odporúčam 3 úrovne.

## úroveň 1 — PR required

* unit
* stable integration
* stable golden

## úroveň 2 — nightly/manual

* firmware build
* smoke simulation

## úroveň 3 — future

* synthesis smoke
* vendor tool integration
* packaging/release validation

---

# 7. Presné poradie implementácie v sprinte

Ak by som to robil ja, idem takto:

1. `pyproject.toml` + package-data + markers
2. unit tests stabilize
3. stable integration tests
4. stable golden snapshots
5. docs quickstart + overview
6. CI workflows
7. scripts
8. report stabilization
9. release workflow + changelog

Toto poradie minimalizuje chaos.

---

# 8. Riziká sprintu

Najväčšie riziká:

## 1. nestabilné snapshoty

Ak report alebo emitre ešte menia poradie položiek, golden testy budú flaky.

### riešenie

* všade explicitne sortovať:

  * artifacts
  * registers
  * clocks
  * regions

## 2. toolchain-heavy fixtures blokujú CI

### riešenie

* označiť markermi
* oddeliť stable a extended lane

## 3. template files nie sú v package

### riešenie

* `package-data` v `pyproject.toml`

---

# 9. Definition of done pre sprint 1

Sprint 1 je hotový, keď:

* `pip install -e .` funguje
* `pytest tests/unit` green
* `pytest tests/integration -k "not picorv32 and not sim"` green
* `pytest tests/golden` green pre stable fixtures
* GitHub Actions CI green na PR
* README + getting started hotové
* nightly/manual workflow pripravený pre firmware/sim lane

---

# 10. Môj praktický odporúčaný checkpoint názov

Checkpoint by som pomenoval:

```text
milestone/m1-hardened-core
```

alebo tag:

```text
v0.1.0-internal
```

To je podľa mňa vhodný moment na prvý interný milestone.

---

# 11. Čo by som robil po sprinte 1

Až keď bude sprint 1 hotový, išiel by som ďalej jedným z týchto smerov:

* **Wishbone bridge RTL**
* **schema export / docs generation**
* **PicoRV32 IRQ ABI final verification**
* **register-block richer semantics**
* **vendor IP import cleanup**

Najpraktickejšie by podľa mňa bolo:
**Wishbone bridge RTL + second adapter demo**

To by bol veľmi silný dôkaz rozšíriteľnosti frameworku.

Ak chceš, dám ti hneď ďalším krokom aj **presný backlog pre sprint 1 rozdelený na deň 1 / deň 2 / deň 3**, aby sa to dalo reálne odpracovať.
