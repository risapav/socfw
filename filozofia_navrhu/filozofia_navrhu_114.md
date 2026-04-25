## Commit 50 — portable provenance paths

Cieľ:

* odstrániť absolútne cesty z reportov
* spraviť `build_summary.md` aj `build_provenance.json` prenosné medzi strojmi
* pripraviť stabilné golden snapshoty pre CI

Názov commitu:

```text
reports: normalize provenance paths for portable snapshots
```

## Pridať

```text
socfw/reports/path_normalizer.py
tests/unit/test_report_path_normalizer.py
```

## Upraviť

```text
socfw/build/full_pipeline.py
socfw/reports/build_summary.py
tests/integration/test_build_provenance_json_artifact.py
```

---

## `socfw/reports/path_normalizer.py`

```python
from __future__ import annotations

from pathlib import Path


class ReportPathNormalizer:
    def __init__(self, *, out_dir: str, repo_root: str | None = None) -> None:
        self.out_dir = Path(out_dir).resolve()
        self.repo_root = Path(repo_root).resolve() if repo_root else Path.cwd().resolve()

    def normalize(self, path: str) -> str:
        p = Path(path).resolve()

        try:
            return f"$OUT/{p.relative_to(self.out_dir)}"
        except ValueError:
            pass

        try:
            return f"$REPO/{p.relative_to(self.repo_root)}"
        except ValueError:
            pass

        return str(p)

    def normalize_list(self, paths: list[str]) -> list[str]:
        return sorted(dict.fromkeys(self.normalize(p) for p in paths))
```

---

## `full_pipeline.py`

Pred vytvorením `BuildProvenance`:

```python
from socfw.reports.path_normalizer import ReportPathNormalizer
```

```python
normalizer = ReportPathNormalizer(out_dir=request.out_dir)

vendor_qip = normalizer.normalize_list(vendor.qip_files)
vendor_sdc = normalizer.normalize_list(vendor.sdc_files)
generated = normalizer.normalize_list(built.generated_files)
```

A v provenance použi:

```python
vendor_qip_files=vendor_qip,
vendor_sdc_files=vendor_sdc,
generated_files=generated,
```

---

## `tests/unit/test_report_path_normalizer.py`

```python
from socfw.reports.path_normalizer import ReportPathNormalizer


def test_report_path_normalizer_out_dir(tmp_path):
    out = tmp_path / "out"
    out.mkdir()
    fp = out / "rtl" / "soc_top.sv"
    fp.parent.mkdir()
    fp.write_text("", encoding="utf-8")

    n = ReportPathNormalizer(out_dir=str(out), repo_root=str(tmp_path))
    assert n.normalize(str(fp)) == "$OUT/rtl/soc_top.sv"


def test_report_path_normalizer_repo_root(tmp_path):
    out = tmp_path / "out"
    out.mkdir()
    fp = tmp_path / "packs" / "vendor" / "ip.qip"
    fp.parent.mkdir(parents=True)
    fp.write_text("", encoding="utf-8")

    n = ReportPathNormalizer(out_dir=str(out), repo_root=str(tmp_path))
    assert n.normalize(str(fp)) == "$REPO/packs/vendor/ip.qip"
```

---

## Integration očakávanie

V JSON teste zmeň assertion:

```python
assert any(p.startswith("$OUT/") for p in data["generated_files"])
assert any(p.startswith("$REPO/") for p in data["vendor_qip_files"])
```

---

## Definition of Done

Commit 50 je hotový, keď:

* reporty neobsahujú machine-specific absolútne cesty
* generated files sú `$OUT/...`
* repo artifacts sú `$REPO/...`
* JSON provenance je snapshot-friendly

Ďalší commit:

```text
golden: snapshot JSON provenance reports for vendor anchors
```
