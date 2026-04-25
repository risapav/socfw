## Commit 48 — native artifact inventory + deduplikácia generated files

Cieľ:

* prestať ručne appendovať súbory na mnohých miestach
* mať jeden centrálny inventory objekt pre build artefakty
* stabilizovať `BuildResult.generated_files`
* pripraviť pôdu pre lepší build report a debug

Názov commitu:

```text
build: add native artifact inventory and remove generated-files duplication
```

## Pridať

```text
socfw/build/artifacts.py
tests/unit/test_build_artifacts.py
```

## Upraviť

```text
socfw/build/result.py
socfw/build/full_pipeline.py
socfw/reports/build_summary.py
tests/integration/test_build_summary_artifact.py
```

---

## `socfw/build/artifacts.py`

```python
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path


@dataclass(frozen=True)
class BuildArtifact:
    path: str
    kind: str
    producer: str


@dataclass
class BuildArtifactInventory:
    artifacts: list[BuildArtifact] = field(default_factory=list)

    def add(self, path: str, *, kind: str, producer: str) -> None:
        self.artifacts.append(
            BuildArtifact(
                path=str(Path(path)),
                kind=kind,
                producer=producer,
            )
        )

    def paths(self) -> list[str]:
        return sorted(dict.fromkeys(a.path for a in self.artifacts))

    def by_kind(self, kind: str) -> list[BuildArtifact]:
        return sorted(
            [a for a in self.artifacts if a.kind == kind],
            key=lambda a: a.path,
        )

    def normalized(self) -> list[BuildArtifact]:
        seen = set()
        out = []
        for a in sorted(self.artifacts, key=lambda x: (x.kind, x.path, x.producer)):
            key = (a.path, a.kind, a.producer)
            if key in seen:
                continue
            seen.add(key)
            out.append(a)
        return out
```

---

## `socfw/build/result.py`

Rozšír:

```python
from __future__ import annotations

from dataclasses import dataclass, field

from socfw.build.artifacts import BuildArtifactInventory


@dataclass
class BuildResult:
    ok: bool = False
    diagnostics: list = field(default_factory=list)
    generated_files: list[str] = field(default_factory=list)
    provenance: object | None = None
    artifacts: BuildArtifactInventory = field(default_factory=BuildArtifactInventory)

    def add_file(self, path: str, *, kind: str = "file", producer: str = "unknown") -> None:
        self.generated_files.append(path)
        self.artifacts.add(path, kind=kind, producer=producer)

    def normalize_files(self) -> None:
        self.generated_files = sorted(dict.fromkeys(self.generated_files + self.artifacts.paths()))
```

---

## Úprava `FullBuildPipeline._build_native`

Namiesto:

```python
generated_files.append(...)
```

použi inventory:

```python
result = BuildResult(ok=True)

top = self.rtl_emitter.emit_top(...)
result.add_file(top, kind="rtl", producer="rtl_emitter")

for fp in _copy_bridge_artifacts(...):
    result.add_file(fp, kind="rtl", producer="bridge_artifact_copy")

files_tcl = self.files_tcl_emitter.emit(...)
result.add_file(files_tcl, kind="tcl", producer="files_tcl_emitter")

sdc = self.sdc_emitter.emit(...)
result.add_file(sdc, kind="timing", producer="sdc_emitter")

board_tcl = self.board_tcl_emitter.emit(...)
result.add_file(board_tcl, kind="tcl", producer="board_tcl_emitter")

result.normalize_files()
return result
```

A v hlavnom `build()` po summary:

```python
summary_path = self.summary.write(request.out_dir, provenance)
built.add_file(summary_path, kind="report", producer="build_summary")
built.normalize_files()
```

---

## `BuildProvenance` doplnok

Ak chceš už teraz využiť inventory:

```python
artifact_kinds: dict[str, int] = field(default_factory=dict)
```

V pipeline:

```python
artifact_kinds = {}
for a in built.artifacts.normalized():
    artifact_kinds[a.kind] = artifact_kinds.get(a.kind, 0) + 1
```

A do provenance:

```python
artifact_kinds=artifact_kinds
```

---

## `build_summary.py`

Pridaj sekciu:

```python
lines.append("## Artifact Inventory")
lines.append("")
if getattr(provenance, "artifact_kinds", None):
    for kind in sorted(provenance.artifact_kinds):
        lines.append(f"- {kind}: `{provenance.artifact_kinds[kind]}`")
else:
    lines.append("- none")
lines.append("")
```

---

## `tests/unit/test_build_artifacts.py`

```python
from socfw.build.artifacts import BuildArtifactInventory


def test_build_artifact_inventory_deduplicates_paths():
    inv = BuildArtifactInventory()
    inv.add("out/rtl/soc_top.sv", kind="rtl", producer="rtl")
    inv.add("out/rtl/soc_top.sv", kind="rtl", producer="rtl")

    assert inv.paths() == ["out/rtl/soc_top.sv"]
    assert len(inv.normalized()) == 1


def test_build_artifact_inventory_filters_by_kind():
    inv = BuildArtifactInventory()
    inv.add("a.sv", kind="rtl", producer="x")
    inv.add("b.tcl", kind="tcl", producer="y")

    assert len(inv.by_kind("rtl")) == 1
    assert inv.by_kind("rtl")[0].path == "a.sv"
```

---

## Definition of Done

Commit 48 je hotový, keď:

* native build používa `BuildArtifactInventory`
* `generated_files` sú stabilné a deduplikované
* build summary ukazuje artifact counts
* všetky golden testy sú aktualizované

Ďalší commit:

```text
reports: add JSON build provenance export
```
