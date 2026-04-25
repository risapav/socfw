## Commit 37 — použiteľné schema chyby namiesto raw Pydantic výpisov

Cieľ:

* chyby typu `Field required [type=missing...]` nahradiť praktickým vysvetlením
* pri `project.yaml` a `timing_config.yaml` ukázať:

  * čo chýba
  * čo framework očakáva
  * ako to opraviť
* ponechať raw detail iba ako doplnkový hint

Názov commitu:

```text
diagnostics: replace raw schema errors with actionable config hints
```

## Pridať

```text
socfw/config/schema_errors.py
tests/unit/test_schema_error_messages.py
```

## Upraviť

```text
socfw/config/project_loader.py
socfw/config/timing_loader.py
socfw/config/ip_loader.py
socfw/config/board_loader.py
```

---

## `socfw/config/schema_errors.py`

```python
from __future__ import annotations

from pydantic import ValidationError

from socfw.core.diagnostics import Diagnostic, Severity


def _loc_to_path(loc) -> str:
    return ".".join(str(x) for x in loc)


def format_pydantic_issue(exc: Exception) -> str:
    if isinstance(exc, ValidationError):
        parts = []
        for err in exc.errors():
            loc = _loc_to_path(err.get("loc", ()))
            msg = err.get("msg", "invalid value")
            parts.append(f"{loc}: {msg}")
        return "; ".join(parts)

    return str(exc)


def project_schema_error(exc: Exception, *, file: str) -> Diagnostic:
    detail = format_pydantic_issue(exc)

    hints = [
        "Use canonical project schema v2.",
        "Expected top-level keys: version, kind, project, registries, clocks, modules.",
        "Project metadata must be under `project:`.",
        "Use `timing.file`, not `timing.config`, unless alias normalization is enabled.",
        "Use list-style modules: `modules: [ { instance, type, ... } ]`.",
        f"Raw schema detail: {detail}",
    ]

    return Diagnostic(
        code="PRJ100",
        severity=Severity.ERROR,
        message="Invalid project YAML schema",
        subject="project",
        file=file,
        hints=tuple(hints),
    )


def timing_schema_error(exc: Exception, *, file: str) -> Diagnostic:
    detail = format_pydantic_issue(exc)

    hints = [
        "Use canonical timing schema v2.",
        "Expected shape: version: 2, kind: timing, timing: { clocks, io_delays, false_paths }.",
        "If your file has top-level `clocks`, `io_delays`, or `false_paths`, wrap them under `timing:`.",
        "Example: timing: { clocks: [...], io_delays: {...}, false_paths: [...] }.",
        f"Raw schema detail: {detail}",
    ]

    return Diagnostic(
        code="TIM100",
        severity=Severity.ERROR,
        message="Invalid timing YAML schema",
        subject="timing",
        file=file,
        hints=tuple(hints),
    )


def ip_schema_error(exc: Exception, *, file: str) -> Diagnostic:
    detail = format_pydantic_issue(exc)

    return Diagnostic(
        code="IP100",
        severity=Severity.ERROR,
        message="Invalid IP descriptor YAML schema",
        subject="ip",
        file=file,
        hints=(
            "Expected shape: version: 2, kind: ip, ip: { name, module, category }.",
            "Artifacts should be under `artifacts.synthesis`, `artifacts.simulation`, `artifacts.metadata`.",
            f"Raw schema detail: {detail}",
        ),
    )


def board_schema_error(exc: Exception, *, file: str) -> Diagnostic:
    detail = format_pydantic_issue(exc)

    return Diagnostic(
        code="BRD100",
        severity=Severity.ERROR,
        message="Invalid board YAML schema",
        subject="board",
        file=file,
        hints=(
            "Expected shape: version, kind: board, board, fpga, system, resources.",
            "System clock must be under `system.clock`.",
            "Board resources should define kind/top_name/pin or pins.",
            f"Raw schema detail: {detail}",
        ),
    )
```

---

## Úprava `project_loader.py`

Namiesto:

```python
Diagnostic(
    code="PRJ100",
    severity=Severity.ERROR,
    message=f"Invalid project YAML: {exc2}",
    ...
)
```

použi:

```python
from socfw.config.schema_errors import project_schema_error
```

a v error branch:

```python
return Result(diagnostics=[project_schema_error(exc2, file=path)])
```

Ak máš fallback alias/legacy mapping, použi error z posledného zlyhania.

---

## Úprava `timing_loader.py`

Import:

```python
from socfw.config.schema_errors import timing_schema_error
```

Potom:

```python
return Result(diagnostics=[timing_schema_error(exc2, file=path)])
```

---

## Úprava `ip_loader.py`

```python
from socfw.config.schema_errors import ip_schema_error
```

a:

```python
return Result(diagnostics=[ip_schema_error(exc2, file=path)])
```

---

## Úprava `board_loader.py`

```python
from socfw.config.schema_errors import board_schema_error
```

a:

```python
return Result(diagnostics=[board_schema_error(exc, file=path)])
```

---

## Test `tests/unit/test_schema_error_messages.py`

```python
from pydantic import BaseModel, ValidationError

from socfw.config.schema_errors import project_schema_error, timing_schema_error


class DemoSchema(BaseModel):
    timing: dict


def test_timing_schema_error_has_actionable_hints():
    try:
        DemoSchema.model_validate({})
    except ValidationError as exc:
        d = timing_schema_error(exc, file="timing_config.yaml")

    assert d.code == "TIM100"
    assert d.message == "Invalid timing YAML schema"
    assert any("wrap them under `timing:`" in h for h in d.hints)
    assert any("Raw schema detail" in h for h in d.hints)


def test_project_schema_error_mentions_modules_shape():
    try:
        DemoSchema.model_validate({})
    except ValidationError as exc:
        d = project_schema_error(exc, file="project.yaml")

    assert d.code == "PRJ100"
    assert any("list-style modules" in h for h in d.hints)
```

---

## Očakávaný nový výstup

Namiesto:

```text
ERROR TIM100 timing
Invalid timing YAML: 1 validation error for TimingDocumentSchema
timing Field required ...
```

chcem:

```text
ERROR TIM100: Invalid timing YAML schema
  at: timing_config.yaml
  hint: Use canonical timing schema v2.
  hint: Expected shape: version: 2, kind: timing, timing: { clocks, io_delays, false_paths }.
  hint: If your file has top-level `clocks`, `io_delays`, or `false_paths`, wrap them under `timing:`.
  hint: Raw schema detail: timing: Field required
```

---

## Dôležitá poznámka

Toto nerieši len estetiku.
Toto je zásadné pre použiteľnosť frameworku, lebo používateľ musí vedieť opraviť YAML bez čítania Pydantic dokumentácie.

Ďalší commit:

```text
cli: add socfw doctor for resolved config inspection
```
