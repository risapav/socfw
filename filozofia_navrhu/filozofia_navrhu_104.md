## Commit 40 — normalizačná vrstva + alias reporting

Cieľ:

* oddeliť raw YAML od canonical dokumentu
* mať jeden výstup typu: “toto som normalizoval”
* dostať aliasy do `doctor` aj `build_summary`
* pripraviť pôdu pre `socfw fmt`

Názov commitu:

```text
config: add normalization layer and alias reporting
```

## Pridať

```text
socfw/config/normalized.py
socfw/config/normalizers/__init__.py
socfw/config/normalizers/project.py
socfw/config/normalizers/timing.py
tests/unit/test_normalized_config.py
```

## Upraviť

```text
socfw/config/project_loader.py
socfw/config/timing_loader.py
socfw/model/source_context.py
socfw/diagnostics/doctor.py
socfw/build/provenance.py
socfw/reports/build_summary.py
```

---

## `socfw/config/normalized.py`

```python
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class NormalizedDocument:
    data: dict
    diagnostics: list = field(default_factory=list)
    aliases_used: list[str] = field(default_factory=list)
```

---

## `socfw/config/normalizers/project.py`

```python
from __future__ import annotations

from socfw.config.aliases import normalize_project_aliases
from socfw.config.normalized import NormalizedDocument


def normalize_project_document(data: dict, *, file: str) -> NormalizedDocument:
    normalized, diags = normalize_project_aliases(data, file=file)

    aliases = []
    for d in diags:
        if getattr(d, "code", "").startswith("PRJ_ALIAS"):
            aliases.append(d.message)

    return NormalizedDocument(
        data=normalized,
        diagnostics=diags,
        aliases_used=aliases,
    )
```

---

## `socfw/config/normalizers/timing.py`

```python
from __future__ import annotations

from socfw.config.aliases import normalize_timing_aliases
from socfw.config.normalized import NormalizedDocument


def normalize_timing_document(data: dict, *, file: str) -> NormalizedDocument:
    normalized, diags = normalize_timing_aliases(data, file=file)

    aliases = []
    for d in diags:
        if getattr(d, "code", "").startswith("TIM_ALIAS"):
            aliases.append(d.message)

    return NormalizedDocument(
        data=normalized,
        diagnostics=diags,
        aliases_used=aliases,
    )
```

---

## `socfw/model/source_context.py`

Doplň alias reporting:

```python
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class SourceContext:
    project_file: str | None = None
    board_file: str | None = None
    timing_file: str | None = None
    ip_files: dict[str, str] = field(default_factory=dict)
    cpu_files: dict[str, str] = field(default_factory=dict)
    pack_roots: list[str] = field(default_factory=list)
    ip_search_dirs: list[str] = field(default_factory=list)
    cpu_search_dirs: list[str] = field(default_factory=list)
    aliases_used: list[str] = field(default_factory=list)
```

---

## Úprava `project_loader.py`

Namiesto priameho volania `normalize_project_aliases` použi normalizer.

```python
from socfw.config.normalizers.project import normalize_project_document
```

V `load()`:

```python
data = raw.value or {}

norm = normalize_project_document(data, file=path)
data = norm.data
```

Diagnostiky:

```python
diags = list(norm.diagnostics)
```

A do `ProjectModel.raw` môžeš uložiť už canonical:

```python
raw=doc.model_dump()
```

Voliteľne do `ProjectModel` doplň `aliases_used`, ale jednoduchšie je niesť to v `Result` diagnostikách a neskôr v `SourceContext`.

---

## Úprava `timing_loader.py`

```python
from socfw.config.normalizers.timing import normalize_timing_document
```

V `load()`:

```python
data = raw.value or {}

norm = normalize_timing_document(data, file=path)
data = norm.data
```

Diagnostiky:

```python
diags = list(norm.diagnostics)
```

---

## Ako dostať `aliases_used` do `SystemModel.sources`

Najjednoduchšie:

V `SystemLoader.load()` po project load a timing load pozbieraj warningy z diagnostics:

```python
aliases_used = [
    d.message
    for d in diags
    if str(getattr(d, "code", "")).endswith("ALIAS001")
    or "ALIAS" in str(getattr(d, "code", ""))
]
```

A do `SourceContext`:

```python
aliases_used=aliases_used,
```

Presnejší variant je mať `Result.metadata`, ale na tento commit stačí diagnostiky.

---

## Úprava `doctor.py`

Pridaj sekciu:

```python
lines.append("## Compatibility aliases")
if system.sources.aliases_used:
    for a in sorted(system.sources.aliases_used):
        lines.append(f"- {a}")
else:
    lines.append("- none")
lines.append("")
```

---

## Úprava `socfw/build/provenance.py`

Doplň:

```python
aliases_used: list[str] = field(default_factory=list)
```

Celý doplnok:

```python
@dataclass
class BuildProvenance:
    ...
    aliases_used: list[str] = field(default_factory=list)
```

---

## Úprava `full_pipeline.py`

Pri skladaní `BuildProvenance`:

```python
aliases_used=list(system.sources.aliases_used),
```

---

## Úprava `build_summary.py`

Pridaj sekciu pred Generated Files:

```python
lines.append("## Compatibility Aliases")
lines.append("")
if provenance.aliases_used:
    for alias in sorted(provenance.aliases_used):
        lines.append(f"- {alias}")
else:
    lines.append("- none")
lines.append("")
```

---

## `tests/unit/test_normalized_config.py`

```python
from socfw.config.normalizers.project import normalize_project_document
from socfw.config.normalizers.timing import normalize_timing_document


def test_project_normalizer_reports_aliases():
    norm = normalize_project_document(
        {"timing": {"config": "timing_config.yaml"}},
        file="project.yaml",
    )

    assert norm.data["timing"]["file"] == "timing_config.yaml"
    assert norm.aliases_used
    assert any("timing.config" in a for a in norm.aliases_used)


def test_timing_normalizer_reports_aliases():
    norm = normalize_timing_document(
        {
            "version": 2,
            "kind": "timing",
            "clocks": [],
        },
        file="timing_config.yaml",
    )

    assert "timing" in norm.data
    assert norm.aliases_used
```

---

## Definition of Done

Commit 40 je hotový, keď:

* normalizácia je oddelená od loaderov
* alias warnings stále fungujú
* `doctor` ukazuje použité aliasy
* `build_summary.md` ukazuje použité aliasy
* testy sú green

Ďalší commit:

```text
cli: add socfw fmt for canonical YAML rewriting
```
