Áno. Tu je **Commit 23 ako file-by-file scaffold**:

# Commit 23 — golden snapshot pre `build_summary.md` pri `vendor_pll_soc` a `vendor_sdram_soc`

Cieľ tohto commitu:

* uzamknúť nový `build_summary.md` ako súčasť regression coverage
* potvrdiť, že reporting je:

  * deterministický
  * stabilný
  * použiteľný ako build provenance anchor
* rozšíriť golden coverage o posledný dôležitý nový-flow artifact

Po tomto commite už nebude golden coverage chrániť len:

* `soc_top.sv`
* `files.tcl`
* `board.tcl`
* `soc_top.sdc`
* `bridge_summary.txt`

ale aj:

* **report, ktorý build vysvetľuje**

To je veľmi dôležité pred cutover governance.

---

# Názov commitu

```text
golden: snapshot build_summary artifacts for converged vendor fixtures
```

---

# 1. Čo má byť výsledok po Commite 23

Po tomto commite má platiť:

```bash
socfw build tests/golden/fixtures/vendor_pll_soc/project.yaml --out build/vendor_pll_soc
socfw build tests/golden/fixtures/vendor_sdram_soc/project.yaml --out build/vendor_sdram_soc

pytest tests/golden/test_vendor_pll_soc_golden.py
pytest tests/golden/test_vendor_sdram_soc_golden.py
```

A očakávaš:

* oba golden testy porovnávajú aj:

  * `reports/build_summary.md`
* report je stabilný medzi runmi
* golden coverage zachytí regressions v:

  * CPU/IP summary
  * vendor artifact summary
  * bridge summary
  * generated file inventory

---

# 2. Súbory, ktoré pridať

```text
tests/golden/expected/vendor_pll_soc/reports/build_summary.md
tests/golden/expected/vendor_sdram_soc/reports/build_summary.md
```

---

# 3. Súbory, ktoré upraviť

```text
tests/golden/test_vendor_pll_soc_golden.py
tests/golden/test_vendor_sdram_soc_golden.py
socfw/reports/build_summary.py
```

Voliteľne:

```text
socfw/build/full_pipeline.py
```

ale len ak potrebuješ dotiahnuť ordering vstupov do provenance.

---

# 4. Kľúčové rozhodnutie pre Commit 23

Správny scope je:

## snapshotnúť report, ale ešte z neho nerobiť príliš “smart” artefakt

To znamená:

* žiadne timestamps
* žiadne durations
* žiadne absolute host-specific noise
* žiadne non-deterministic ordering

Ak report ešte obsahuje niečo nestabilné, teraz to treba odstrániť.

Toto je presne commit na:

* final cleanup formattingu
* deterministic ordering
* golden locking

---

# 5. úprava `socfw/reports/build_summary.py`

Aby golden snapshoty neflakovali, report musí mať stabilné poradie sekcií aj položiek.

Ak už používaš verziu z Commitu 22, je skoro správna.
Teraz ju len jemne dotiahni.

## odporúčaná verzia

```python
from __future__ import annotations

from pathlib import Path

from socfw.build.provenance import BuildProvenance


class BuildSummaryReport:
    def build(self, provenance: BuildProvenance) -> str:
        lines: list[str] = []

        lines.append("# Build Summary")
        lines.append("")
        lines.append("## Project")
        lines.append("")
        lines.append(f"- Name: `{provenance.project_name}`")
        lines.append(f"- Mode: `{provenance.project_mode}`")
        lines.append(f"- Board: `{provenance.board_id}`")
        lines.append("")

        lines.append("## CPU")
        lines.append("")
        if provenance.cpu_type is None:
            lines.append("- CPU: none")
        else:
            lines.append(f"- CPU type: `{provenance.cpu_type}`")
            if provenance.cpu_module:
                lines.append(f"- CPU module: `{provenance.cpu_module}`")
        lines.append("")

        lines.append("## Modules and IP")
        lines.append("")
        if provenance.module_instances:
            for name in sorted(provenance.module_instances):
                lines.append(f"- Module instance: `{name}`")
        else:
            lines.append("- Module instances: none")
        lines.append("")

        if provenance.ip_types:
            for name in sorted(provenance.ip_types):
                lines.append(f"- IP type: `{name}`")
        else:
            lines.append("- IP types: none")
        lines.append("")

        lines.append("## Timing")
        lines.append("")
        lines.append(f"- Generated clocks: `{provenance.timing_generated_clocks}`")
        lines.append(f"- False paths: `{provenance.timing_false_paths}`")
        lines.append("")

        lines.append("## Vendor Artifacts")
        lines.append("")
        if provenance.vendor_qip_files:
            for qip in sorted(provenance.vendor_qip_files):
                lines.append(f"- QIP: `{qip}`")
        else:
            lines.append("- QIP: none")

        if provenance.vendor_sdc_files:
            for sdc in sorted(provenance.vendor_sdc_files):
                lines.append(f"- SDC: `{sdc}`")
        else:
            lines.append("- Vendor SDC: none")
        lines.append("")

        lines.append("## Bridges")
        lines.append("")
        if provenance.bridge_pairs:
            for pair in sorted(provenance.bridge_pairs):
                lines.append(f"- `{pair}`")
        else:
            lines.append("- none")
        lines.append("")

        lines.append("## Generated Files")
        lines.append("")
        if provenance.generated_files:
            for fp in sorted(provenance.generated_files):
                lines.append(f"- `{fp}`")
        else:
            lines.append("- none")
        lines.append("")

        return "\n".join(lines).rstrip() + "\n"

    def write(self, out_dir: str, provenance: BuildProvenance) -> str:
        reports_dir = Path(out_dir) / "reports"
        reports_dir.mkdir(parents=True, exist_ok=True)
        out_file = reports_dir / "build_summary.md"
        out_file.write_text(self.build(provenance), encoding="utf-8")
        return str(out_file)
```

### čo je dôležité

* `sorted(...)` na všetkom, čo môže byť list
* stabilný trailing newline
* žiadne runtime-dependent údaje

To je presne to, čo potrebuje golden.

---

# 6. Voliteľná úprava `socfw/build/full_pipeline.py`

Ak chceš mať istotu, že `generated_files` nevstupujú do provenance v nestabilnom stave, nech tam ostane tento sled:

```python
        built = self.legacy.build(system=system, request=request)
        built.diagnostics = diags + list(built.diagnostics)
        built.normalize_files()
```

a až potom:

```python
        provenance = BuildProvenance(
            ...
            generated_files=list(built.generated_files),
        )
```

To je ideálne.

Ak to tak už máš, netreba meniť.

---

# 7. úprava `tests/golden/test_vendor_pll_soc_golden.py`

Teraz treba pridať porovnanie reportu natvrdo.

## nahradiť týmto

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
    _assert_same(out_dir / "reports" / "build_summary.md", expected_root / "reports" / "build_summary.md")
```

---

# 8. úprava `tests/golden/test_vendor_sdram_soc_golden.py`

Pridaj to isté pre SDRAM fixture.

## nahradiť týmto

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


def test_vendor_sdram_soc_golden(tmp_path):
    out_dir = tmp_path / "out"

    result = FullBuildPipeline().build(
        BuildRequest(
            project_file="tests/golden/fixtures/vendor_sdram_soc/project.yaml",
            out_dir=str(out_dir),
        )
    )

    assert result.ok, [f"{d.code}: {d.message}" for d in result.diagnostics]

    expected_root = Path("tests/golden/expected/vendor_sdram_soc")

    _assert_same(out_dir / "rtl" / "soc_top.sv", expected_root / "rtl" / "soc_top.sv")
    _assert_same(out_dir / "hal" / "files.tcl", expected_root / "hal" / "files.tcl")
    _assert_same(out_dir / "reports" / "bridge_summary.txt", expected_root / "reports" / "bridge_summary.txt")
    _assert_same(out_dir / "reports" / "build_summary.md", expected_root / "reports" / "build_summary.md")

    timing_expected = expected_root / "timing" / "soc_top.sdc"
    timing_generated = out_dir / "timing" / "soc_top.sdc"
    if timing_expected.exists():
        _assert_same(timing_generated, timing_expected)
```

---

# 9. Ako vytvoriť expected `build_summary.md`

Po tom, čo sú buildy stabilné, sprav jednorazovo:

```bash
socfw build tests/golden/fixtures/vendor_pll_soc/project.yaml --out build/vendor_pll_soc
socfw build tests/golden/fixtures/vendor_sdram_soc/project.yaml --out build/vendor_sdram_soc

mkdir -p tests/golden/expected/vendor_pll_soc/reports
mkdir -p tests/golden/expected/vendor_sdram_soc/reports

cp build/vendor_pll_soc/reports/build_summary.md tests/golden/expected/vendor_pll_soc/reports/build_summary.md
cp build/vendor_sdram_soc/reports/build_summary.md tests/golden/expected/vendor_sdram_soc/reports/build_summary.md
```

---

# 10. Čo ak `build_summary.md` flakuje kvôli absolútnym cestám

Toto je pravdepodobné.
Najčastejšie to bude v sekcii:

* `Vendor Artifacts`
* `Generated Files`

Ak ti to vadí pre golden snapshoty, máš dve rozumné možnosti.

## možnosť A — snapshotovať absolútne cesty

Jednoduchšie, ale menej prenosné.

## možnosť B — normalizovať report na cesty relatívne k `out_dir` alebo repo root

Toto je lepšie.

### odporúčanie

Ak chceš report dlhodobo stabilný a prenosný, uprav `BuildSummaryReport` tak, aby:

* generated files boli relatívne k `out_dir`
* vendor files boli relatívne k repo root alebo descriptor root

Na Commit 23 by som to spravil len ak reálne narazíš na flaky golden kvôli absolútnym cestám.

Ak buildy bežia v stabilnom lokálnom CI prostredí a snapshotuješ v tom istom repo, môžeš to odložiť.

---

# 11. Ak chceš rovno lepšiu prenosnosť reportu

Tu je praktický upgrade bez veľkého scope nárastu:

### do `BuildSummaryReport.write(...)`

nepridávaj absolútnu logiku

### ale v `FullBuildPipeline`

pred odovzdaním provenance premapuj generated files na relative-to-out-dir, napr.:

```python
from pathlib import Path

out_root = Path(request.out_dir).resolve()
rel_generated = []
for fp in built.generated_files:
    p = Path(fp).resolve()
    try:
        rel_generated.append(str(p.relative_to(out_root)))
    except Exception:
        rel_generated.append(str(p))
```

A do provenance daj:

```python
generated_files=sorted(rel_generated)
```

Podobne môžeš časom spraviť aj pre vendor artifact paths.
Na Commit 23 je to voliteľné, ale dobrý upgrade.

---

# 12. Čo v tomto commite ešte **nerobiť**

Vedome by som nechal bokom:

* JSON provenance export
* timestamps
* build durations
* stage-by-stage report
* cutover governance dokumenty
* legacy freeze policy

Commit 23 má vyriešiť len:

* snapshot build summary reportu

To je správny scope.

---

# 13. Čo po Commite 23 overiť

Spusti:

```bash
pip install -e .
socfw build tests/golden/fixtures/vendor_pll_soc/project.yaml --out build/vendor_pll_soc
socfw build tests/golden/fixtures/vendor_sdram_soc/project.yaml --out build/vendor_sdram_soc

pytest tests/golden/test_vendor_pll_soc_golden.py
pytest tests/golden/test_vendor_sdram_soc_golden.py
```

### očakávanie

* golden green
* reporty green
* opakované runy nemenia snapshoty

To je veľmi dôležitý checkpoint pred governance/cutover krokom.

---

# 14. Definition of Done pre Commit 23

Commit 23 je hotový, keď:

* `build_summary.md` existuje pre vendor PLL aj vendor SDRAM fixture
* oba golden testy ho porovnávajú
* report je deterministický
* golden coverage je green

To je veľmi silný finishing krok pre reporting vrstvu Phase 1/2 convergence.

---

# 15. Čo má byť Commit 24

Po tomto by som išiel už skôr na governance/cutover krok:

## Commit 24

```text
cutover: add migration status board and mark converged fixtures as new-flow anchors
```

Ten prinesie:

* oficiálny zoznam migračných statusov
* označenie:

  * `blink_converged`
  * `vendor_pll_soc`
  * `vendor_sdram_soc`
    ako nové-flow anchors
* prvý formálny krok k default switchu

To je podľa mňa teraz najlepší ďalší krok.

---

# 16. Môj praktický odporúčaný rytmus

Po Commite 23:

1. nechaj prebehnúť pár opakovaných test runov
2. ak golden drží, nerob už ďalšie technické experimenty paralelne
3. prepnúť sa na:

   * migration status board
   * cutover readiness
   * legacy freeze planning

To je správny moment presunúť sa z čisto technického convergence do riadeného cutoveru.

Ak chceš, ďalšia správa môže byť presne:
👉 **Commit 24 ako file-by-file scaffold: migration status board + označenie converged fixtures ako new-flow anchors**
