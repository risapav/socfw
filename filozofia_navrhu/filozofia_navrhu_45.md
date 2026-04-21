Dobre, poďme to spraviť prakticky a realisticky — **3-dňový hardening sprint**, ktorý vieš reálne odpracovať bez chaosu.

Cieľ: na konci máš **stabilný, buildovateľný, testovaný repo + CI + prvý milestone**.

---

# 🧭 Sprint 1 plán (3 dni)

## 🔵 Deň 1 — stabilizácia jadra + testy (najdôležitejší deň)

### 🎯 cieľ dňa

* všetko sa dá nainštalovať
* unit + základné integration testy sú green
* žiadne “random breakage”

---

## 1.1 Packaging (ráno)

### uprav:

* `pyproject.toml`

```toml
[build-system]
requires = ["setuptools>=68", "wheel"]
build-backend = "setuptools.build_meta"

[tool.setuptools.packages.find]
include = ["socfw*"]

[tool.setuptools.package-data]
socfw = ["templates/*.j2"]

[tool.pytest.ini_options]
testpaths = ["tests"]
pythonpath = ["."]
markers = [
  "toolchain_required: requires external compiler toolchain",
  "sim_required: requires simulator",
  "golden: snapshot comparison tests",
]
```

### test:

```bash
pip install -e .
socfw --help
```

👉 Ak toto nefunguje → STOP, oprav hneď.

---

## 1.2 Unit testy (dopoludnie)

### pridaj/over:

* `tests/unit/test_board_loader.py`
* `tests/unit/test_project_loader.py`
* `tests/unit/test_ip_loader.py`
* `tests/unit/test_validation.py`

### minimálne testy:

✔ valid board load
✔ valid project load
✔ ip catalog load
✔ overlap detection
✔ missing CPU
✔ missing bridge

### run:

```bash
pytest tests/unit
```

👉 musí byť **100% green**

---

## 1.3 Integration testy (poobede)

### súbory:

* `test_build_blink01.py`
* `test_build_blink02.py`
* `test_build_soc_led.py`

### iba smoke checky:

```python
assert (out_dir / "rtl" / "soc_top.sv").exists()
assert "module soc_top" in text
```

### run:

```bash
pytest tests/integration -k "not picorv32 and not sim"
```

👉 musí byť stabilné

---

## 1.4 Stabilizácia ordering (večer)

TOTO JE KRITICKÉ pre golden testy.

### skontroluj:

* všetky `dict` iterácie → zoradiť
* register blocks → sorted
* clocks → sorted
* endpoints → sorted
* artifacts → sorted

Typické fixy:

```python
for k in sorted(my_dict):
    ...
```

👉 ak toto nespravíš, deň 2 bude peklo

---

## ✅ Výstup dňa 1

* funguje `pip install -e .`
* unit testy green
* integration testy green
* build pipeline stabilná

---

# 🟡 Deň 2 — golden snapshots + docs

### 🎯 cieľ dňa

* snapshot testy fungujú
* docs dávajú zmysel
* framework je čitateľný

---

## 2.1 Golden fixtures (ráno)

### snapshotuj:

* `blink_test_01`
* `blink_test_02`
* `soc_led_test`

### ulož:

```text
tests/golden/expected/<fixture>/
```

### súbory:

* `rtl/soc_top.sv`
* `hal/board.tcl`
* `timing/soc_top.sdc`
* `sw/soc_map.h`
* `docs/soc_map.md`
* `reports/build_report.md`

---

## 2.2 Golden test runner

### `tests/golden/test_golden_outputs.py`

```python
def assert_same(a, b):
    assert a.read_text() == b.read_text()
```

### run:

```bash
pytest tests/golden
```

👉 musí byť stabilné pri opakovanom spustení

---

## 2.3 README + quickstart (dopoludnie)

### `README.md`

minimum:

```md
# socfw

Config-driven SoC/FPGA framework.

## Quickstart

socfw validate <project.yaml>
socfw build <project.yaml> --out build/gen
```

---

## 2.4 Getting started (poobede)

### `docs/user/getting_started.md`

Obsah:

* install
* validate
* build
* kde sú výstupy

---

## 2.5 Architecture overview (večer)

### `docs/architecture/00_overview.md`

Popíš pipeline:

```text
YAML → loaders → validation → elaboration → IR → emit → reports
```

---

## ✅ Výstup dňa 2

* golden testy green
* docs existujú
* repo je pochopiteľné

---

# 🟢 Deň 3 — CI + scripts + release skeleton

### 🎯 cieľ dňa

* PR automaticky testuje repo
* máš lokálne skripty
* repo vyzerá “profesionálne”

---

## 3.1 CI workflow (ráno)

### `.github/workflows/ci.yml`

minimal:

```yaml
jobs:
  unit:
    ...
    - pytest tests/unit

  integration:
    ...
    - pytest tests/integration -k "not picorv32 and not sim"

  golden:
    ...
    - pytest tests/golden
```

---

## 3.2 scripts (dopoludnie)

### `scripts/run_smoke.sh`

```bash
pytest tests/unit
pytest tests/integration -k "not picorv32 and not sim"
```

### `scripts/run_golden.sh`

```bash
pytest tests/golden
```

---

## 3.3 CI local runner (poobede)

### `scripts/run_ci_local.sh`

```bash
pytest tests/unit
pytest tests/integration
pytest tests/golden
```

---

## 3.4 Changelog + license (poobede)

### `CHANGELOG.md`

```md
## 0.1.0
- simple_bus SoC
- IRQ controller
- firmware flow
- AXI bridge planning
```

---

## 3.5 Release workflow (večer)

### `.github/workflows/release.yml`

* build package
* upload artifacts

---

## 3.6 Final sanity run

```bash
pip install -e .
scripts/run_ci_local.sh
```

👉 musí byť green

---

## ✅ Výstup dňa 3

* CI beží
* golden testy bežia v CI
* repo je release-ready
* máš reproducible build

---

# 🧱 Celkový výsledok sprintu

Po 3 dňoch máš:

✔ stabilný build pipeline
✔ test coverage (unit + integration + golden)
✔ reproducible outputs
✔ CI pipeline
✔ docs + quickstart
✔ pripravený release milestone

---

# ⚠️ Najčastejšie chyby (na ktoré si daj pozor)

## 1. golden testy flakujú

→ fix: **sort everywhere**

## 2. templates sa nenačítajú

→ fix: `package-data`

## 3. CI padá na toolchain

→ fix: markers + skip

## 4. integration testy sú príliš prísne

→ fix: len smoke checks

---

# 🏁 Milestone

Po tomto sprinte odporúčam:

```bash
git tag v0.1.0-internal
```

alebo branch:

```text
milestone/m1-hardened-core
```

---

# 🚀 Čo robiť potom (správny ďalší krok)

Najväčší value ďalší krok:

👉 **Wishbone bridge RTL + druhý adapter demo**

pretože:

* dokážeš, že bridge registry nie je len teória
* máš 2 rôzne protokoly
* architektúra sa potvrdí

---

Ak chceš, ďalší krok ti viem rozkresliť úplne presne:

👉 **Wishbone bridge implementácia (RTL + planner + test fixture)**
