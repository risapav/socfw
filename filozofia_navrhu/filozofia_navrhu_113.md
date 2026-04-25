## Commit 49 — JSON build provenance export

Cieľ:

* popri `build_summary.md` generovať aj strojovo čitateľný report
* umožniť CI, tooling a budúce GUI bez parsovania Markdownu
* stabilizovať build provenance ako API výstup

Názov commitu:

```text
reports: add JSON build provenance export
```

## Pridať

```text
socfw/reports/build_provenance_json.py
tests/unit/test_build_provenance_json.py
tests/integration/test_build_provenance_json_artifact.py
```

## Upraviť

```text
socfw/build/provenance.py
socfw/build/full_pipeline.py
tests/golden/test_vendor_pll_soc_golden.py
tests/golden/test_vendor_sdram_soc_golden.py
```

---

## `socfw/reports/build_provenance_json.py`

```python
from __future__ import annotations

from dataclasses import asdict, is_dataclass
from pathlib import Path
import json


class BuildProvenanceJsonReport:
    def build(self, provenance) -> str:
        if is_dataclass(provenance):
            data = asdict(provenance)
        else:
            data = dict(provenance)

        return json.dumps(
            data,
            indent=2,
            sort_keys=True,
            ensure_ascii=False,
        ) + "\n"

    def write(self, out_dir: str, provenance) -> str:
        reports_dir = Path(out_dir) / "reports"
        reports_dir.mkdir(parents=True, exist_ok=True)

        out_file = reports_dir / "build_provenance.json"
        out_file.write_text(self.build(provenance), encoding="utf-8")
        return str(out_file)
```

---

## `socfw/build/full_pipeline.py`

Import:

```python
from socfw.reports.build_provenance_json import BuildProvenanceJsonReport
```

V `__init__`:

```python
self.provenance_json = BuildProvenanceJsonReport()
```

Po markdown summary:

```python
summary_path = self.summary.write(request.out_dir, provenance)
built.add_file(summary_path, kind="report", producer="build_summary")

json_path = self.provenance_json.write(request.out_dir, provenance)
built.add_file(json_path, kind="report", producer="build_provenance_json")

built.normalize_files()
```

---

## `tests/unit/test_build_provenance_json.py`

```python
import json

from socfw.build.provenance import BuildProvenance
from socfw.reports.build_provenance_json import BuildProvenanceJsonReport


def test_build_provenance_json_report_is_stable_json():
    provenance = BuildProvenance(
        project_name="demo",
        project_mode="soc",
        board_id="qmtech_ep4ce55",
        ip_types=["sdram_ctrl"],
        module_instances=["sdram0"],
        bridge_pairs=["sdram0: simple_bus -> wishbone"],
        generated_files=["rtl/soc_top.sv"],
    )

    text = BuildProvenanceJsonReport().build(provenance)
    data = json.loads(text)

    assert data["project_name"] == "demo"
    assert data["board_id"] == "qmtech_ep4ce55"
    assert data["bridge_pairs"] == ["sdram0: simple_bus -> wishbone"]
```

---

## `tests/integration/test_build_provenance_json_artifact.py`

```python
import json

from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline


def test_build_writes_json_provenance_artifact(tmp_path):
    out_dir = tmp_path / "out"

    result = FullBuildPipeline().build(
        BuildRequest(
            project_file="tests/golden/fixtures/vendor_sdram_soc/project.yaml",
            out_dir=str(out_dir),
        )
    )

    assert result.ok, [f"{d.code}: {d.message}" for d in result.diagnostics]

    json_file = out_dir / "reports" / "build_provenance.json"
    assert json_file.exists()

    data = json.loads(json_file.read_text(encoding="utf-8"))
    assert data["project_name"] == "vendor_sdram_soc"
    assert data["board_id"] == "qmtech_ep4ce55"
    assert "sdram_ctrl" in data["ip_types"]
    assert "sdram0: simple_bus -> wishbone" in data["bridge_pairs"]
```

---

## Golden update

Ak chceš JSON hneď snapshotovať, pridaj do golden testov:

```python
_assert_same(
    out_dir / "reports" / "build_provenance.json",
    expected_root / "reports" / "build_provenance.json",
)
```

A vytvor expected:

```bash
socfw build tests/golden/fixtures/vendor_pll_soc/project.yaml --out build/vendor_pll_soc
socfw build tests/golden/fixtures/vendor_sdram_soc/project.yaml --out build/vendor_sdram_soc

cp build/vendor_pll_soc/reports/build_provenance.json tests/golden/expected/vendor_pll_soc/reports/build_provenance.json
cp build/vendor_sdram_soc/reports/build_provenance.json tests/golden/expected/vendor_sdram_soc/reports/build_provenance.json
```

---

## Dôležitá poznámka

Ak JSON obsahuje absolútne cesty, snapshoty budú menej prenosné.
Odporúčam v ďalšom commite normalizovať cesty v provenance na relative-to-output alebo relative-to-repo.

---

## Definition of Done

Commit 49 je hotový, keď:

* build generuje `reports/build_provenance.json`
* JSON je validný a deterministický
* integration test overuje obsah
* voliteľne golden snapshoty pokrývajú JSON

Ďalší commit:

```text
reports: normalize provenance paths for portable snapshots
```
