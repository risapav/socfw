Áno. Tu je **Commit 22 ako file-by-file scaffold**:

# Commit 22 — prvý deterministic build summary / provenance artifact pre nový flow

Cieľ tohto commitu:

* aby `socfw build` vedel **sám vysvetliť**, čo sa stalo
* zaviesť prvý ľahký, ale užitočný **provenance/build summary artifact**
* mať stabilný report pre:

  * vstupný projekt
  * resolved board
  * použité IP/CPU
  * timing info
  * vendor artifacts
  * bridge summary
  * generated files

Toto je správny krok po:

* `blink_converged`
* `vendor_pll_soc`
* `vendor_sdram_soc`

Lebo teraz už má framework dosť vertikálnych slice-ov na to, aby build summary mal reálnu hodnotu.

---

# Názov commitu

```text
report: add first deterministic build summary and provenance artifact for new flow
```

---

# 1. Čo má byť výsledok po Commite 22

Po tomto commite má platiť:

```bash
socfw build tests/golden/fixtures/vendor_pll_soc/project.yaml --out build/vendor_pll_soc
socfw build tests/golden/fixtures/vendor_sdram_soc/project.yaml --out build/vendor_sdram_soc
```

A v oboch výstupoch očakávaš nový artifact, napr.:

```text
reports/build_summary.md
```

ktorý obsahuje minimálne:

* project name
* board
* mode
* CPU summary
* IP list
* timing summary
* vendor artifact summary
* bridge summary
* generated files list

A report je:

* deterministický
* snapshotovateľný
* čitateľný

---

# 2. Súbory, ktoré pridať

```text
socfw/build/provenance.py
socfw/reports/build_summary.py
tests/unit/test_build_summary_report.py
tests/integration/test_build_summary_artifact.py
```

---

# 3. Súbory, ktoré upraviť

```text
socfw/build/result.py
socfw/build/full_pipeline.py
legacy_build.py
```

Voliteľne:

```text
tests/golden/test_vendor_pll_soc_golden.py
tests/golden/test_vendor_sdram_soc_golden.py
```

ak chceš hneď snapshotovať aj nový report.

---

# 4. Kľúčové rozhodnutie pre Commit 22

Správny scope je:

## nerobiť ešte plný stage timing/cache system

Na tento commit stačí **V1 provenance**:

* statický summary z `SystemModel`
* summary z generated files
* summary z vendor artifacts
* summary z bridge pairs

To znamená:

* nie stopky
* nie cache hit/miss
* nie full stage graph

To príde neskôr, ak budeš chcieť reporting v2.

---

# 5. `socfw/build/provenance.py`

Toto je malý model pre build summary vstupy.

```python
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class BuildProvenance:
    project_name: str
    project_mode: str
    board_id: str

    cpu_type: str | None = None
    cpu_module: str | None = None

    ip_types: list[str] = field(default_factory=list)
    module_instances: list[str] = field(default_factory=list)

    timing_generated_clocks: int = 0
    timing_false_paths: int = 0

    vendor_qip_files: list[str] = field(default_factory=list)
    vendor_sdc_files: list[str] = field(default_factory=list)

    bridge_pairs: list[str] = field(default_factory=list)

    generated_files: list[str] = field(default_factory=list)
```

---

# 6. `socfw/reports/build_summary.py`

Toto je hlavný nový report formatter.

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
            for name in provenance.module_instances:
                lines.append(f"- Module instance: `{name}`")
        else:
            lines.append("- Module instances: none")
        lines.append("")

        if provenance.ip_types:
            for name in provenance.ip_types:
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
            for qip in provenance.vendor_qip_files:
                lines.append(f"- QIP: `{qip}`")
        else:
            lines.append("- QIP: none")

        if provenance.vendor_sdc_files:
            for sdc in provenance.vendor_sdc_files:
                lines.append(f"- SDC: `{sdc}`")
        else:
            lines.append("- Vendor SDC: none")
        lines.append("")

        lines.append("## Bridges")
        lines.append("")
        if provenance.bridge_pairs:
            for pair in provenance.bridge_pairs:
                lines.append(f"- `{pair}`")
        else:
            lines.append("- none")
        lines.append("")

        lines.append("## Generated Files")
        lines.append("")
        if provenance.generated_files:
            for fp in provenance.generated_files:
                lines.append(f"- `{fp}`")
        else:
            lines.append("- none")
        lines.append("")

        return "\n".join(lines)

    def write(self, out_dir: str, provenance: BuildProvenance) -> str:
        reports_dir = Path(out_dir) / "reports"
        reports_dir.mkdir(parents=True, exist_ok=True)
        out_file = reports_dir / "build_summary.md"
        out_file.write_text(self.build(provenance), encoding="utf-8")
        return str(out_file)
```

### prečo markdown

Lebo:

* je čitateľný
* snapshot-friendly
* nepotrebuje ďalší viewer
* dobre sa hodí do golden testov

---

# 7. úprava `socfw/build/result.py`

Treba doplniť provenance.

## nahradiť týmto

```python
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class BuildResult:
    ok: bool = False
    diagnostics: list = field(default_factory=list)
    generated_files: list[str] = field(default_factory=list)
    provenance: object | None = None

    def add_file(self, path: str) -> None:
        self.generated_files.append(path)

    def normalize_files(self) -> None:
        self.generated_files = sorted(dict.fromkeys(self.generated_files))
```

---

# 8. helpery v `legacy_build.py`

Tu už máš:

* `_write_or_patch_files_tcl`
* `_write_bridge_summary`
* `_collect_bridge_pairs`

Teraz z toho treba vedieť vytiahnuť dáta pre report.

Ak ešte nemáš `_collect_bridge_pairs(system)` ako samostatný helper, nechaj ho samostatný.
Bude sa z neho čítať report.

Nemusíš hneď meniť jeho obsah, len nech je reusable.

---

# 9. úprava `socfw/build/full_pipeline.py`

Tu sa spraví provenance a zapíše report.

## nahradiť týmto

```python
from __future__ import annotations

from socfw.build.legacy_backend import LegacyBackend
from socfw.build.provenance import BuildProvenance
from socfw.build.result import BuildResult
from socfw.build.vendor_artifacts import collect_vendor_artifacts
from socfw.config.system_loader import SystemLoader
from socfw.reports.build_summary import BuildSummaryReport
from socfw.validate.runner import ValidationRunner


def _collect_bridge_pairs_for_report(system) -> list[str]:
    pairs = []

    for mod in system.project.modules:
        if mod.bus is None:
            continue

        fabric = system.project.fabric_by_name(mod.bus.fabric)
        if fabric is None:
            continue

        ip = system.ip_catalog.get(mod.type_name)
        if ip is None:
            continue

        iface = ip.slave_bus_interface()
        if iface is None:
            continue

        if fabric.protocol != iface.protocol:
            pairs.append(f"{mod.instance}: {fabric.protocol} -> {iface.protocol}")

    return sorted(dict.fromkeys(pairs))


class FullBuildPipeline:
    def __init__(self) -> None:
        self.loader = SystemLoader()
        self.validator = ValidationRunner()
        self.legacy = LegacyBackend()
        self.summary = BuildSummaryReport()

    def validate(self, project_file: str):
        loaded = self.loader.load(project_file)
        if loaded.ok and loaded.value is not None:
            loaded.extend(self.validator.run(loaded.value))
        return loaded

    def build(self, request) -> BuildResult:
        loaded = self.validate(request.project_file)

        diags = list(loaded.diagnostics)
        if not loaded.ok or loaded.value is None:
            return BuildResult(ok=False, diagnostics=diags, generated_files=[])

        system = loaded.value
        built = self.legacy.build(system=system, request=request)
        built.diagnostics = diags + list(built.diagnostics)
        built.normalize_files()

        vendor = collect_vendor_artifacts(system)
        cpu_desc = system.cpu_desc()

        provenance = BuildProvenance(
            project_name=system.project.name,
            project_mode=system.project.mode,
            board_id=system.board.board_id,
            cpu_type=system.project.cpu.type_name if system.project.cpu is not None else None,
            cpu_module=cpu_desc.module if cpu_desc is not None else None,
            ip_types=sorted(dict.fromkeys(m.type_name for m in system.project.modules)),
            module_instances=sorted(dict.fromkeys(m.instance for m in system.project.modules)),
            timing_generated_clocks=len(system.timing.generated_clocks) if system.timing is not None else 0,
            timing_false_paths=len(system.timing.false_paths) if system.timing is not None else 0,
            vendor_qip_files=vendor.qip_files,
            vendor_sdc_files=vendor.sdc_files,
            bridge_pairs=_collect_bridge_pairs_for_report(system),
            generated_files=list(built.generated_files),
        )

        built.provenance = provenance

        summary_path = self.summary.write(request.out_dir, provenance)
        built.generated_files.append(summary_path)
        built.normalize_files()

        return built
```

### prečo helper `_collect_bridge_pairs_for_report`

Aby `FullBuildPipeline` nebol závislý na interných helperoch z `legacy_build.py`.

---

# 10. `tests/unit/test_build_summary_report.py`

Tento test overí formatter.

```python
from socfw.build.provenance import BuildProvenance
from socfw.reports.build_summary import BuildSummaryReport


def test_build_summary_report_contains_key_sections():
    provenance = BuildProvenance(
        project_name="demo",
        project_mode="soc",
        board_id="qmtech_ep4ce55",
        cpu_type="dummy_cpu",
        cpu_module="dummy_cpu",
        ip_types=["blink_test", "sdram_ctrl"],
        module_instances=["blink0", "sdram0"],
        timing_generated_clocks=1,
        timing_false_paths=2,
        vendor_qip_files=["/tmp/sdram_ctrl.qip"],
        vendor_sdc_files=["/tmp/sdram_ctrl.sdc"],
        bridge_pairs=["sdram0: simple_bus -> wishbone"],
        generated_files=["/tmp/out/rtl/soc_top.sv"],
    )

    text = BuildSummaryReport().build(provenance)

    assert "# Build Summary" in text
    assert "qmtech_ep4ce55" in text
    assert "dummy_cpu" in text
    assert "sdram0: simple_bus -> wishbone" in text
    assert "sdram_ctrl.qip" in text
```

---

# 11. `tests/integration/test_build_summary_artifact.py`

Toto je hlavný integration test commitu.

```python
from pathlib import Path

from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline


def test_build_writes_build_summary_artifact(tmp_path):
    out_dir = tmp_path / "out"

    result = FullBuildPipeline().build(
        BuildRequest(
            project_file="tests/golden/fixtures/vendor_sdram_soc/project.yaml",
            out_dir=str(out_dir),
        )
    )

    assert result.ok, [f"{d.code}: {d.message}" for d in result.diagnostics]

    summary = out_dir / "reports" / "build_summary.md"
    assert summary.exists()

    text = summary.read_text(encoding="utf-8")
    assert "# Build Summary" in text
    assert "vendor_sdram_soc" in text
    assert "qmtech_ep4ce55" in text
    assert "sdram0: simple_bus -> wishbone" in text
    assert "sdram_ctrl.qip" in text
```

---

# 12. Voliteľná úprava golden testov

Ak chceš hneď snapshotovať aj report, doplň do golden testov.

## `tests/golden/test_vendor_pll_soc_golden.py`

Doplň:

```python
    summary_expected = expected_root / "reports" / "build_summary.md"
    summary_generated = out_dir / "reports" / "build_summary.md"
    if summary_expected.exists():
        _assert_same(summary_generated, summary_expected)
```

## `tests/golden/test_vendor_sdram_soc_golden.py`

Doplň to isté.

### ale praktické odporúčanie

Na Commit 22 by som najprv:

* vygeneroval report
* overil stabilitu
* snapshot pridal až v Commite 23

To je bezpečnejšie.

---

# 13. Čo v tomto commite ešte **nerobiť**

Vedome by som nechal bokom:

* stage timings
* cache hit/miss
* JSON provenance export
* report provenance po každom stage
* pretty tables
* CI dashboards

Commit 22 má riešiť len:

* prvý stabilný build summary artifact

To je správny scope.

---

# 14. Čo po Commite 22 overiť

Spusti:

```bash
pip install -e .
socfw build tests/golden/fixtures/vendor_pll_soc/project.yaml --out build/vendor_pll_soc
socfw build tests/golden/fixtures/vendor_sdram_soc/project.yaml --out build/vendor_sdram_soc
pytest tests/unit/test_build_summary_report.py
pytest tests/integration/test_build_summary_artifact.py
```

### očakávanie

* oba buildy green
* report vzniká
* report je čitateľný a deterministický

---

# 15. Definition of Done pre Commit 22

Commit 22 je hotový, keď:

* `BuildResult` nesie provenance
* `reports/build_summary.md` vzniká
* report obsahuje:

  * project
  * board
  * CPU
  * IP
  * timing
  * vendor artifacts
  * bridge summary
  * generated files
* integration test je green

To je veľmi dobrý reporting milestone.

---

# 16. Čo má byť Commit 23

Po tomto by som išiel na:

## Commit 23

```text
golden: snapshot build_summary artifacts for converged vendor fixtures
```

alebo, ak chceš už governance krok:

## Commit 23

```text
cutover: add migration status board and mark converged fixtures as new-flow anchors
```

Môj praktický odporúčaný ďalší krok je:

👉 **najprv snapshotnúť build summary reporty**

Lebo keď už report existuje, chceš ho stabilizovať skôr, než sa stane súčasťou cutover governance.

Ak chceš, ďalšia správa môže byť presne:
👉 **Commit 23 ako file-by-file scaffold: golden snapshot pre `build_summary.md` pri `vendor_pll_soc` a `vendor_sdram_soc`**
