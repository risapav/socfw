Áno. Tu je **Commit 11 ako file-by-file scaffold**:

# Commit 11 — stabilizácia `blink_converged` výstupov + prvé golden coverage

Cieľ tohto commitu:

* prestať sa spoliehať len na “build prešiel”
* zafixovať prvý **nový-style regression anchor**
* mať prvý converged fixture, ktorý je:

  * validovateľný
  * buildovateľný
  * snapshotovateľný

Toto je veľmi dôležitý commit, lebo od tohto bodu už nebude nový flow len experiment, ale začne mať **vlastný regression point**.

---

# Názov commitu

```text
golden: stabilize blink_converged outputs and add first new-flow snapshot coverage
```

---

# 1. Čo má byť výsledok po Commite 11

Po tomto commite má platiť:

```bash
socfw build tests/golden/fixtures/blink_converged/project.yaml --out build/blink_converged
pytest tests/integration/test_build_blink_converged.py
pytest tests/golden -k blink_converged
```

A očakávaš:

* build prejde
* generované súbory sú deterministické
* golden porovnanie je green

---

# 2. Súbory, ktoré pridať

```text
tests/golden/expected/blink_converged/rtl/soc_top.sv
tests/golden/expected/blink_converged/hal/board.tcl
tests/golden/expected/blink_converged/timing/soc_top.sdc
tests/golden/expected/blink_converged/reports/build_report.md
tests/golden/test_blink_converged_golden.py
```

Ak ešte nemáš report output, tak `build_report.md` zatiaľ vynechaj.

---

# 3. Súbory, ktoré upraviť

```text
tests/integration/test_build_blink_converged.py
legacy_build.py
socfw/build/result.py
```

Voliteľne, ak potrebuješ stabilitu:

```text
rtl.py
tcl.py
sdc.py
sw.py
```

ale len minimálne.

---

# 4. Kľúčové rozhodnutie pre Commit 11

Tu je správny prístup:

## ešte nerob full exact golden na všetko, ak build wrapper nie je stabilný

Odporúčam dve fázy v tomto commite:

### fáza A

sprísni integration assertions

### fáza B

golden snapshotuj len tie súbory, ktoré už sú stabilné

Typicky:

* `rtl/soc_top.sv`
* `hal/board.tcl`
* `timing/soc_top.sdc`

Ak report ešte nie je stabilný, odlož ho.

---

# 5. úprava `tests/integration/test_build_blink_converged.py`

Doteraz sme mali mäkké assertions. Teraz ich treba sprísniť.

## nahradiť týmto

```python
from pathlib import Path

from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline


def test_build_blink_converged(tmp_path):
    out_dir = tmp_path / "out"

    result = FullBuildPipeline().build(
        BuildRequest(
            project_file="tests/golden/fixtures/blink_converged/project.yaml",
            out_dir=str(out_dir),
        )
    )

    assert result.ok, [f"{d.code}: {d.message}" for d in result.diagnostics]

    rtl = out_dir / "rtl" / "soc_top.sv"
    board_tcl = out_dir / "hal" / "board.tcl"
    timing_sdc = out_dir / "timing" / "soc_top.sdc"

    assert rtl.exists()
    assert board_tcl.exists()
    assert timing_sdc.exists()

    rtl_text = rtl.read_text(encoding="utf-8")
    assert "module soc_top" in rtl_text
    assert "blink_test" in rtl_text
```

### prečo

Toto už je zmysluplný build test:

* nie len “niečo sa vytvorilo”
* ale konkrétne základné výstupy existujú

---

# 6. úprava `legacy_build.py`

Ak má golden coverage fungovať, potrebuješ mať:

* zber generovaných súborov stabilný
* build wrapper nech vracia všetko konzistentne

## odporúčaná úprava helpera `_collect_generated()`

```python
def _collect_generated(out_dir: str) -> list[str]:
    root = Path(out_dir)
    found = []
    for sub in ["rtl", "hal", "timing", "sw", "docs", "reports"]:
        sp = root / sub
        if sp.exists():
            for fp in sorted(sp.rglob("*")):
                if fp.is_file():
                    found.append(str(fp))
    return found
```

## odporúčaná úprava `build_legacy()`

Na konci nech nevracia duplikáty a nech sú zoradené:

```python
    generated = []
    generated.extend(_collect_generated(out_dir))
    generated = sorted(dict.fromkeys(generated))
    return generated
```

### prečo

To ti stabilizuje:

* CLI output
* `BuildResult.generated_files`
* neskoršie reporty

---

# 7. úprava `socfw/build/result.py`

Voliteľne, ale prakticky pomáha mať helper na deterministiku.

## nahradiť týmto

```python
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class BuildResult:
    ok: bool = False
    diagnostics: list = field(default_factory=list)
    generated_files: list[str] = field(default_factory=list)

    def add_file(self, path: str) -> None:
        self.generated_files.append(path)

    def normalize_files(self) -> None:
        self.generated_files = sorted(dict.fromkeys(self.generated_files))
```

A v `FullBuildPipeline.build()` po `built = self.legacy.build(...)` môžeš doplniť:

```python
        built.normalize_files()
```

To je malá, ale užitočná vec.

---

# 8. nový golden test runner pre `blink_converged`

## `tests/golden/test_blink_converged_golden.py`

```python
from pathlib import Path

from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _assert_same(generated: Path, expected: Path):
    assert generated.exists(), f"Missing generated file: {generated}"
    assert expected.exists(), f"Missing expected file: {expected}"
    assert _read(generated) == _read(expected)


def test_blink_converged_golden(tmp_path):
    out_dir = tmp_path / "out"

    result = FullBuildPipeline().build(
        BuildRequest(
            project_file="tests/golden/fixtures/blink_converged/project.yaml",
            out_dir=str(out_dir),
        )
    )

    assert result.ok, [f"{d.code}: {d.message}" for d in result.diagnostics]

    expected_root = Path("tests/golden/expected/blink_converged")

    _assert_same(out_dir / "rtl" / "soc_top.sv", expected_root / "rtl" / "soc_top.sv")
    _assert_same(out_dir / "hal" / "board.tcl", expected_root / "hal" / "board.tcl")
    _assert_same(out_dir / "timing" / "soc_top.sdc", expected_root / "timing" / "soc_top.sdc")
```

### prečo zatiaľ bez `build_report.md`

Lebo ak ešte nemáš nový report builder alebo legacy report nie je stabilný, netlačil by som to tam silou.

---

# 9. Ako vytvoriť expected golden súbory

Po tom, čo `socfw build` prejde na `blink_converged`, sprav jednorazovo:

```bash
socfw build tests/golden/fixtures/blink_converged/project.yaml --out build/blink_converged
mkdir -p tests/golden/expected/blink_converged/rtl
mkdir -p tests/golden/expected/blink_converged/hal
mkdir -p tests/golden/expected/blink_converged/timing

cp build/blink_converged/rtl/soc_top.sv tests/golden/expected/blink_converged/rtl/soc_top.sv
cp build/blink_converged/hal/board.tcl tests/golden/expected/blink_converged/hal/board.tcl
cp build/blink_converged/timing/soc_top.sdc tests/golden/expected/blink_converged/timing/soc_top.sdc
```

Až potom zapni golden test.

---

# 10. Čo ak golden snapshot flakuje

Toto je veľmi pravdepodobné.
Najčastejšie dôvody budú:

* poradie súborov v generated includes
* poradie portov/modulov
* poradie timing constraints
* path formatting

## čo robiť

Ak snapshot flakuje, neopravuj to v teste. Oprav to v generátore.

### typické opravy

* `sorted(...)` pri:

  * files listoch
  * module listoch
  * outputs
  * constraints
* deterministic top-level port order
* deterministic bind order

---

# 11. Ktoré staré súbory možno bude treba jemne stabilizovať

Len ak snapshoty nie sú stabilné.

## `rtl.py`

Možno bude treba:

* zoradiť input sources
* zoradiť ports / instances

## `tcl.py`

Možno bude treba:

* zoradiť assignment lines

## `sdc.py`

Možno bude treba:

* zoradiť generated clock definitions

## `sw.py`

Na `blink_converged` asi ešte nie

### dôležité

Ak stabilizuješ, rob to len:

* explicitným sortom
* nie zmenou architektúry

---

# 12. Čo v tomto commite ešte **nerobiť**

Vedome by som nechal bokom:

* vendor PLL fixture
* vendor packy
* nový report builder
* nový emitter stack
* CPU-aware SoC fixture
* golden pre legacy `project_config.yaml`

Commit 11 má uzavrieť len:

* prvý converged blink regression anchor

To je správny scope.

---

# 13. Čo po Commite 11 overiť

Spusti:

```bash
pip install -e .
socfw validate tests/golden/fixtures/blink_converged/project.yaml
socfw build tests/golden/fixtures/blink_converged/project.yaml --out build/blink_converged
pytest tests/integration/test_build_blink_converged.py
pytest tests/golden/test_blink_converged_golden.py
```

### očakávanie

* validate green
* build green
* integration green
* golden green

To je veľmi dôležitý checkpoint.

---

# 14. Definition of Done pre Commit 11

Commit 11 je hotový, keď:

* `blink_converged` sa buildí novým CLI
* build generuje stabilné súbory
* integration test overuje konkrétne artefakty
* golden snapshot je green

To je prvý skutočný nový-flow regression míľnik.

---

# 15. Čo má byť Commit 12

Po tomto by som išiel priamo na:

## Commit 12

```text
fixture: add converged pll project and typed timing coverage
```

To prinesie:

* druhý converged fixture
* generated clock reálny use-case
* prvý krok k vendor PLL convergence

To je ďalší prirodzený krok.

---

# 16. Môj praktický odporúčaný rytmus

Po Commite 11:

1. najprv potvrď, že `blink_converged` je stabilný
2. nechaj ho chvíľu ako regression anchor
3. až potom pridaj PLL converged fixture
4. až potom vendor PLL pack

To je správny convergence rytmus.

Ak chceš, ďalšia správa môže byť presne:
👉 **Commit 12 ako file-by-file scaffold: converged PLL fixture + typed timing coverage + build test**
