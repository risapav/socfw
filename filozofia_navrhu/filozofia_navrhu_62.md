Áno. Tu je **Commit 1 ako konkrétny file-by-file scaffold** pre Phase 1 — s cieľom dostať do repa úplne prvý nový základ bez rizikového zásahu do legacy flow.

Tento commit má spraviť len toto:

* zaviesť nový Python package `socfw`
* spraviť inštalovateľný CLI entrypoint
* vytiahnuť renderer z `base.py`
* zaviesť základné `Result` a `Diagnostic`
* pridať common YAML loader

**Nič zo starého flow ešte neláme.**

---

# Commit 1

## názov commitu

```text
core: add socfw package skeleton, renderer, diagnostics, and yaml loading
```

---

# 1. Súbory, ktoré pridať

```text
pyproject.toml
socfw/__init__.py
socfw/cli/main.py
socfw/core/diagnostics.py
socfw/core/result.py
socfw/config/common.py
socfw/emit/renderer.py
```

---

# 2. `pyproject.toml`

Ak ešte neexistuje, pridaj:

```toml
[build-system]
requires = ["setuptools>=68", "wheel"]
build-backend = "setuptools.build_meta"

[project]
name = "socfw"
version = "0.1.0"
description = "Config-driven FPGA/SoC framework"
requires-python = ">=3.11"
dependencies = [
  "PyYAML>=6.0",
  "Jinja2>=3.1",
]

[project.scripts]
socfw = "socfw.cli.main:main"

[tool.setuptools.packages.find]
include = ["socfw*"]
```

Ak už `pyproject.toml` máš, tak len doplň:

* `project.scripts`
* `setuptools.packages.find`

---

# 3. `socfw/__init__.py`

```python
__all__ = ["__version__"]

__version__ = "0.1.0"
```

---

# 4. `socfw/core/diagnostics.py`

Toto je minimum, s ktorým sa už dá žiť:

```python
from __future__ import annotations

from dataclasses import dataclass
from enum import Enum


class Severity(str, Enum):
    INFO = "info"
    WARNING = "warning"
    ERROR = "error"


@dataclass(frozen=True)
class Diagnostic:
    code: str
    severity: Severity
    message: str
    subject: str
    file: str | None = None
    path: str | None = None
    hints: tuple[str, ...] = ()
```

---

# 5. `socfw/core/result.py`

```python
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Generic, TypeVar

from socfw.core.diagnostics import Severity

T = TypeVar("T")


@dataclass
class Result(Generic[T]):
    value: T | None = None
    diagnostics: list = field(default_factory=list)

    @property
    def ok(self) -> bool:
        for d in self.diagnostics:
            sev = getattr(d, "severity", None)
            if sev == Severity.ERROR or getattr(sev, "value", None) == "error":
                return False
        return True
```

---

# 6. `socfw/config/common.py`

Toto je prvý spoločný loader utility modul:

```python
from __future__ import annotations

from pathlib import Path
import yaml

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.core.result import Result


def load_yaml_file(path: str) -> Result[dict]:
    p = Path(path)

    if not p.exists():
        return Result(diagnostics=[
            Diagnostic(
                code="IO001",
                severity=Severity.ERROR,
                message=f"YAML file not found: {path}",
                subject="io",
                file=path,
            )
        ])

    try:
        raw = p.read_text(encoding="utf-8")
    except Exception as exc:
        return Result(diagnostics=[
            Diagnostic(
                code="IO002",
                severity=Severity.ERROR,
                message=f"Failed to read YAML file: {exc}",
                subject="io",
                file=path,
            )
        ])

    try:
        data = yaml.safe_load(raw)
    except Exception as exc:
        return Result(diagnostics=[
            Diagnostic(
                code="YAML001",
                severity=Severity.ERROR,
                message=f"Failed to parse YAML: {exc}",
                subject="yaml",
                file=path,
            )
        ])

    if data is None:
        data = {}

    if not isinstance(data, dict):
        return Result(diagnostics=[
            Diagnostic(
                code="YAML002",
                severity=Severity.ERROR,
                message="Top-level YAML document must be a mapping/object",
                subject="yaml",
                file=path,
            )
        ])

    return Result(value=data)
```

---

# 7. `socfw/emit/renderer.py`

Tu vytiahni užitočnú časť z `base.py`, ale sprav ju čistejšie.

```python
from __future__ import annotations

from pathlib import Path

from jinja2 import Environment, FileSystemLoader, StrictUndefined


def _sv_param(value):
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, int):
        return str(value)
    if value is None:
        return '""'
    return f'"{value}"'


class Renderer:
    def __init__(self, templates_dir: str) -> None:
        self.templates_dir = templates_dir
        self.env = Environment(
            loader=FileSystemLoader(templates_dir),
            undefined=StrictUndefined,
            trim_blocks=True,
            lstrip_blocks=True,
        )
        self.env.filters["sv_param"] = _sv_param

    def render(self, template_name: str, **context) -> str:
        template = self.env.get_template(template_name)
        return template.render(**context)

    def write_text(self, out_file: str | Path, content: str, encoding: str = "utf-8") -> None:
        out_path = Path(out_file)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(content, encoding=encoding)
```

### poznámka

Toto je zámerne jednoduchšie než legacy `base.py`.
Nechcel by som v novom jadre hneď preniesť:

* ASCII stripping
* skryté normalizácie
* príliš magické write správanie

---

# 8. `socfw/cli/main.py`

Na prvý commit stačí extrémne malý CLI skeleton:

```python
from __future__ import annotations

import argparse

from socfw import __version__


def cmd_version(_args) -> int:
    print(__version__)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="socfw")
    sub = parser.add_subparsers(dest="command", required=True)

    p_ver = sub.add_parser("version", help="Show version")
    p_ver.set_defaults(func=cmd_version)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
```

### prečo takto málo

Lebo Commit 1 má len:

* potvrdiť package install
* potvrdiť entrypoint
* pripraviť pôdu pre ďalší commit

---

# 9. Čo v tomto commite **neupravovať**

Zámerne by som sa ešte nedotýkal:

* `base.py`
* `rtl_builder.py`
* `rtl.py`
* `tcl.py`
* `sdc.py`
* `sw.py`
* `project_config.yaml`
* `board_qmtech_ep4ce55.yaml`

Tento commit má byť maximálne bezpečný.

---

# 10. Čo po commite okamžite overiť

Po Commit 1 spusti:

```bash
pip install -e .
socfw version
```

Očakávaný výsledok:

* editable install prejde
* `socfw version` vypíše `0.1.0`

Ak toto nefunguje, nepokračoval by som ďalej.

---

# 11. Mini test pre Commit 1

Pridal by som aj úplne malý test.

## nový súbor

`tests/unit/test_package_smoke.py`

```python
from socfw import __version__
from socfw.emit.renderer import Renderer


def test_version_exists():
    assert isinstance(__version__, str)
    assert __version__


def test_renderer_constructs(tmp_path):
    tpl_dir = tmp_path / "templates"
    tpl_dir.mkdir()
    (tpl_dir / "hello.j2").write_text("Hello {{ name }}!", encoding="utf-8")

    r = Renderer(str(tpl_dir))
    out = r.render("hello.j2", name="socfw")
    assert out == "Hello socfw!"
```

Tento test je super, lebo okamžite overí:

* importy fungujú
* package funguje
* Jinja renderer funguje

---

# 12. Očakávaný diff rozsah

Tento commit by mal byť:

* malý
* čitateľný
* reviewovateľný do pár minút

V princípe:

* len nové súbory
* bez rizika pre existujúci build

To je presne to, čo chceš na prvý convergence commit.

---

# 13. Čo má byť Commit 2

Hneď po tomto by som spravil:

## Commit 2

```text
catalog: add builtin board pack, board model, and board loader
```

Ten by obsahoval:

* `packs/builtin/.../board.yaml`
* `socfw/model/board.py`
* `socfw/config/board_schema.py`
* `socfw/config/board_loader.py`
* `socfw/catalog/indexer.py`
* `socfw/catalog/board_resolver.py`

A to už bude prvý skutočný funkčný krok convergence.

---

# 14. Môj praktický odporúčaný postup

Ak chceš ísť úplne bezpečne:

1. urob tento Commit 1
2. over:

   * `pip install -e .`
   * `socfw version`
   * `pytest tests/unit/test_package_smoke.py`
3. až potom rob Commit 2

To je najzdravší štart.

Ak chceš, ďalšia správa môže byť hneď rovnako konkrétna:

👉 **Commit 2 ako file-by-file scaffold: built-in board pack + board loader + board resolver**
