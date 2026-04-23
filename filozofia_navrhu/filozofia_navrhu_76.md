Áno. Tu je **Commit 15 ako file-by-file scaffold**:

# Commit 15 — golden snapshot pre `vendor_pll_soc` + ordering stabilization

Cieľ tohto commitu:

* zafixovať `vendor_pll_soc` ako prvý **stabilný vendor regression anchor**
* odstrániť flaky ordering v:

  * `files.tcl`
  * generated file lists
  * prípadne timing exporte
* dostať `vendor_pll_soc` do golden coverage

Toto je veľmi dôležitý commit, lebo po ňom už nebude vendor PLL len “funguje na mojom stroji”, ale bude mať **snapshot guardrail**.

---

# Názov commitu

```text
golden: lock vendor_pll_soc snapshots and stabilize files/timing ordering
```

---

# 1. Čo má byť výsledok po Commite 15

Po tomto commite má platiť:

```bash
socfw build tests/golden/fixtures/vendor_pll_soc/project.yaml --out build/vendor_pll_soc
pytest tests/integration/test_build_vendor_pll_soc.py
pytest tests/golden -k vendor_pll_soc
```

A očakávaš:

* build green
* integration green
* golden green
* opakované buildy dávajú rovnaký obsah snapshotovaných súborov

---

# 2. Súbory, ktoré pridať

```text
tests/golden/expected/vendor_pll_soc/rtl/soc_top.sv
tests/golden/expected/vendor_pll_soc/hal/board.tcl
tests/golden/expected/vendor_pll_soc/hal/files.tcl
tests/golden/expected/vendor_pll_soc/timing/soc_top.sdc
tests/golden/test_vendor_pll_soc_golden.py
```

Ak report ešte nemáš stabilný, zatiaľ ho nesnapshotuj.

---

# 3. Súbory, ktoré upraviť

```text
legacy_build.py
socfw/build/result.py
tests/integration/test_build_vendor_pll_soc.py
```

Voliteľne, ak timing ordering flakuje:

```text
sdc.py
tcl.py
```

Ale len ak je to naozaj nutné.

---

# 4. Kľúčové rozhodnutie pre Commit 15

Správny prístup je:

## snapshotovať len to, čo je už stabilné

Odporúčam snapshotovať:

* `rtl/soc_top.sv`
* `hal/board.tcl`
* `hal/files.tcl`
* `timing/soc_top.sdc`

Ak je `soc_top.sdc` ešte nestabilné, odlož ho o commit neskôr.
Ale ak už ordering vieš upratať malým patchom, pokojne ho zahrň.

---

# 5. Ordering stabilizácia v `legacy_build.py`

Toto je najdôležitejší praktický patch commitu.

Už máš helper, ktorý dopĺňa vendor lines do `files.tcl`. Teraz musí byť výstup deterministický.

## uprav `_write_or_patch_files_tcl()`

Použi tento tvar:

```python
def _write_or_patch_files_tcl(out_dir: str, system) -> str | None:
    if system is None:
        return None

    bundle = collect_vendor_artifacts(system)
    if not bundle.qip_files and not bundle.sdc_files:
        return None

    hal_dir = Path(out_dir) / "hal"
    hal_dir.mkdir(parents=True, exist_ok=True)
    files_tcl = hal_dir / "files.tcl"

    existing = ""
    if files_tcl.exists():
        existing = files_tcl.read_text(encoding="utf-8")

    base_lines = []
    if existing.strip():
        base_lines = existing.rstrip().splitlines()

    vendor_lines = ["# Added by socfw compatibility vendor export"]
    for qip in sorted(bundle.qip_files):
        vendor_lines.append(f"set_global_assignment -name QIP_FILE {qip}")
    for sdc in sorted(bundle.sdc_files):
        vendor_lines.append(f"set_global_assignment -name SDC_FILE {sdc}")

    # remove previously appended compatibility block if rerunning
    cleaned = []
    skip = False
    for line in base_lines:
        if line.strip() == "# Added by socfw compatibility vendor export":
            skip = True
            continue
        if skip and line.startswith("set_global_assignment -name QIP_FILE "):
            continue
        if skip and line.startswith("set_global_assignment -name SDC_FILE "):
            continue
        skip = False
        cleaned.append(line)

    lines = cleaned
    if lines and lines[-1].strip():
        lines.append("")
    lines.extend(vendor_lines)

    content = "\n".join(lines).rstrip() + "\n"
    files_tcl.write_text(content, encoding="utf-8")
    return str(files_tcl)
```

### prečo

Toto rieši tri veci:

* zoradenie vendor riadkov
* žiadne duplikovanie pri opakovanom builde
* stabilný newline tail

To je presne to, čo potrebuje golden test.

---

# 6. Stabilizácia `BuildResult.generated_files`

Ak si to ešte nespravil úplne dôsledne, nech `generated_files` sú vždy:

* bez duplikátov
* zoradené

## úprava `socfw/build/result.py`

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

A v `FullBuildPipeline.build()` nech zostane:

```python
        built = self.legacy.build(system=loaded.value, request=request)
        built.diagnostics = diags + list(built.diagnostics)
        built.normalize_files()
        return built
```

---

# 7. Voliteľná stabilizácia timing outputu

Ak `timing/soc_top.sdc` flakuje kvôli poradiu generated clocks alebo false paths, oprav to na najnižšej možnej vrstve.

## možnosť A

Ak starý `sdc.py` skladá clock constraints z listov/dictov, pridaj `sorted(...)`.

Typicky:

* generated clock definitions
* false path lines
* helper sections

## možnosť B

Ak je timing output už stabilný, nerob nič.

Na tomto commite by som sa timingu dotkol len vtedy, ak golden snapshot reálne padá.

---

# 8. úprava `tests/integration/test_build_vendor_pll_soc.py`

Integration test teraz môže zostať skoro rovnaký, ale odporúčam doplniť assertion, že build je deterministicky vendor-aware.

## nahradiť týmto

```python
from pathlib import Path

from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline


def test_build_vendor_pll_soc(tmp_path):
    out_dir = tmp_path / "out"

    result = FullBuildPipeline().build(
        BuildRequest(
            project_file="tests/golden/fixtures/vendor_pll_soc/project.yaml",
            out_dir=str(out_dir),
        )
    )

    assert result.ok, [f"{d.code}: {d.message}" for d in result.diagnostics]

    rtl = out_dir / "rtl" / "soc_top.sv"
    board_tcl = out_dir / "hal" / "board.tcl"
    timing_sdc = out_dir / "timing" / "soc_top.sdc"
    files_tcl = out_dir / "hal" / "files.tcl"

    assert rtl.exists()
    assert board_tcl.exists()
    assert timing_sdc.exists()
    assert files_tcl.exists()

    rtl_text = rtl.read_text(encoding="utf-8")
    files_tcl_text = files_tcl.read_text(encoding="utf-8")

    assert "clkpll" in rtl_text
    assert "blink_test" in rtl_text

    assert "QIP_FILE" in files_tcl_text
    assert "clkpll.qip" in files_tcl_text
    assert "SDC_FILE" in files_tcl_text
    assert "clkpll.sdc" in files_tcl_text
```

Ak toto už máš rovnaké z Commitu 14, nechaj ho tak.

---

# 9. `tests/golden/test_vendor_pll_soc_golden.py`

Toto je hlavný nový test commitu.

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


def test_vendor_pll_soc_golden(tmp_path):
    out_dir = tmp_path / "out"

    result = FullBuildPipeline().build(
        BuildRequest(
            project_file="tests/golden/fixtures/vendor_pll_soc/project.yaml",
            out_dir=str(out_dir),
        )
    )

    assert result.ok, [f"{d.code}: {d.message}" for d in result.diagnostics]

    expected_root = Path("tests/golden/expected/vendor_pll_soc")

    _assert_same(out_dir / "rtl" / "soc_top.sv", expected_root / "rtl" / "soc_top.sv")
    _assert_same(out_dir / "hal" / "board.tcl", expected_root / "hal" / "board.tcl")
    _assert_same(out_dir / "hal" / "files.tcl", expected_root / "hal" / "files.tcl")
    _assert_same(out_dir / "timing" / "soc_top.sdc", expected_root / "timing" / "soc_top.sdc")
```

---

# 10. Ako vytvoriť expected golden súbory

Po stabilnom builde sprav jednorazovo:

```bash
socfw build tests/golden/fixtures/vendor_pll_soc/project.yaml --out build/vendor_pll_soc

mkdir -p tests/golden/expected/vendor_pll_soc/rtl
mkdir -p tests/golden/expected/vendor_pll_soc/hal
mkdir -p tests/golden/expected/vendor_pll_soc/timing

cp build/vendor_pll_soc/rtl/soc_top.sv tests/golden/expected/vendor_pll_soc/rtl/soc_top.sv
cp build/vendor_pll_soc/hal/board.tcl tests/golden/expected/vendor_pll_soc/hal/board.tcl
cp build/vendor_pll_soc/hal/files.tcl tests/golden/expected/vendor_pll_soc/hal/files.tcl
cp build/vendor_pll_soc/timing/soc_top.sdc tests/golden/expected/vendor_pll_soc/timing/soc_top.sdc
```

A potom už iba golden test.

---

# 11. Čo ak `board.tcl` alebo `soc_top.sv` tiež flakujú

To je možné.

## správna politika

Nerieš to v teste. Rieš to v generácii.

Typické fixes:

* sort moduly
* sort ports
* sort assignment lines
* stabilizuj bind order

Ak to padá kvôli legacy backendu, urob iba čo najmenší deterministic patch.

---

# 12. Čo v tomto commite ešte **nerobiť**

Vedome by som stále nechal bokom:

* vendor family validator
* vendor SDRAM fixture
* nový report builder
* nový files IR
* nový timing IR/emitter
* migration starých PLL fixtures

Commit 15 má uzavrieť len:

* vendor PLL snapshot stability

To je správny scope.

---

# 13. Čo po Commite 15 overiť

Spusti:

```bash
pip install -e .
socfw build tests/golden/fixtures/vendor_pll_soc/project.yaml --out build/vendor_pll_soc
pytest tests/integration/test_build_vendor_pll_soc.py
pytest tests/golden/test_vendor_pll_soc_golden.py
```

### očakávanie

* build green
* integration green
* golden green
* druhý build dá rovnaký výsledok

---

# 14. Definition of Done pre Commit 15

Commit 15 je hotový, keď:

* `vendor_pll_soc` build je stabilný
* `hal/files.tcl` má stabilné vendor lines
* golden snapshot pre `vendor_pll_soc` je green

To je prvý plnohodnotný vendor regression anchor.

---

# 15. Čo má byť Commit 16

Po tomto by som išiel priamo na:

## Commit 16

```text
board: add external SDRAM resource model and converged vendor SDRAM fixture scaffold
```

To prinesie:

* rozšírenie board modelu pre externú SDRAM resource vetvu
* základ pre `vendor_sdram_soc`
* prípravu na bridge-aware vendor IP convergence

To je ďalší prirodzený krok.

---

# 16. Môj praktický odporúčaný rytmus

Po Commite 15:

1. nechaj `vendor_pll_soc` chvíľu ako regression anchor
2. ak flakuje, oprav len ordering helpers
3. až potom choď na SDRAM
4. nechytaj teraz ďalšie veľké veci paralelne

To je správny convergence rytmus.

Ak chceš, ďalšia správa môže byť presne:
👉 **Commit 16 ako file-by-file scaffold: board external SDRAM resource model + `vendor_sdram_soc` fixture scaffold**
