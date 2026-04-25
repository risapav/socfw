## Commit 41 — `socfw fmt` pre canonical YAML rewriting

Cieľ:

* automaticky prepísať legacy/alias YAML do canonical tvaru
* znížiť ručné chyby pri migrácii
* podporiť hlavne:

  * `project.yaml`
  * `timing_config.yaml`

Názov commitu:

```text
cli: add socfw fmt for canonical YAML rewriting
```

## Pridať

```text
socfw/config/formatter.py
tests/unit/test_config_formatter.py
tests/integration/test_socfw_fmt.py
```

## Upraviť

```text
socfw/cli/main.py
pyproject.toml
```

---

## `socfw/config/formatter.py`

```python
from __future__ import annotations

from pathlib import Path
import yaml

from socfw.config.common import load_yaml_file
from socfw.config.normalizers.project import normalize_project_document
from socfw.config.normalizers.timing import normalize_timing_document
from socfw.core.result import Result
from socfw.core.diagnostics import Diagnostic, Severity


def _dump_yaml(data: dict) -> str:
    return yaml.safe_dump(
        data,
        sort_keys=False,
        allow_unicode=True,
        default_flow_style=False,
    )


class ConfigFormatter:
    def format_file(self, path: str, *, write: bool = False) -> Result[str]:
        loaded = load_yaml_file(path)
        if not loaded.ok:
            return Result(diagnostics=loaded.diagnostics)

        data = loaded.value or {}
        kind = data.get("kind")

        if kind == "project" or "project" in data or "design" in data:
            norm = normalize_project_document(data, file=path)
        elif kind == "timing" or "timing" in data or any(k in data for k in ("clocks", "io_delays", "false_paths")):
            norm = normalize_timing_document(data, file=path)
        else:
            return Result(
                diagnostics=[
                    Diagnostic(
                        code="FMT001",
                        severity=Severity.ERROR,
                        message="Unable to infer YAML document type for formatting",
                        subject="fmt",
                        file=path,
                        hints=("Expected a project or timing YAML document.",),
                    )
                ]
            )

        text = _dump_yaml(norm.data)

        if write:
            Path(path).write_text(text, encoding="utf-8")

        return Result(value=text, diagnostics=norm.diagnostics)
```

---

## Úprava `socfw/cli/main.py`

Pridaj import:

```python
from socfw.config.formatter import ConfigFormatter
```

Handler:

```python
def cmd_fmt(args) -> int:
    res = ConfigFormatter().format_file(args.file, write=args.write)
    _print_diags(res.diagnostics)

    if not res.ok or res.value is None:
        return 1

    if args.write:
        print(f"OK: formatted {args.file}")
    else:
        print(res.value, end="")

    return 0
```

Parser:

```python
p_fmt = sub.add_parser("fmt", help="Format YAML config into canonical shape")
p_fmt.add_argument("file")
p_fmt.add_argument("--write", action="store_true", help="Rewrite file in place")
p_fmt.set_defaults(func=cmd_fmt)
```

Použitie:

```bash
socfw fmt project.yaml
socfw fmt project.yaml --write
socfw fmt timing_config.yaml --write
```

---

## `tests/unit/test_config_formatter.py`

```python
from socfw.config.formatter import ConfigFormatter


def test_format_project_alias_to_canonical(tmp_path):
    p = tmp_path / "project.yaml"
    p.write_text(
        """
version: 2
kind: project
project:
  name: demo
  mode: standalone
  board: qmtech_ep4ce55
timing:
  config: timing_config.yaml
modules:
  blink_test:
    module: blink_test
""",
        encoding="utf-8",
    )

    res = ConfigFormatter().format_file(str(p), write=False)

    assert res.ok
    assert "file: timing_config.yaml" in res.value
    assert "instance: blink_test" in res.value
    assert "type: blink_test" in res.value


def test_format_timing_top_level_to_canonical(tmp_path):
    p = tmp_path / "timing_config.yaml"
    p.write_text(
        """
version: 2
kind: timing
clocks: []
false_paths: []
""",
        encoding="utf-8",
    )

    res = ConfigFormatter().format_file(str(p), write=False)

    assert res.ok
    assert "timing:" in res.value
    assert "clocks: []" in res.value
    assert "false_paths: []" in res.value
```

---

## `tests/integration/test_socfw_fmt.py`

```python
from socfw.config.formatter import ConfigFormatter


def test_fmt_write_rewrites_project_file(tmp_path):
    p = tmp_path / "project.yaml"
    p.write_text(
        """
version: 2
kind: project
project:
  name: demo
  mode: standalone
  board: qmtech_ep4ce55
timing:
  config: timing_config.yaml
modules:
  blink_test:
    module: blink_test
""",
        encoding="utf-8",
    )

    res = ConfigFormatter().format_file(str(p), write=True)
    assert res.ok

    text = p.read_text(encoding="utf-8")
    assert "config:" not in text
    assert "file: timing_config.yaml" in text
    assert "- instance: blink_test" in text
```

---

## `pyproject.toml`

Uisti sa, že dependency obsahuje:

```toml
dependencies = [
  "PyYAML>=6.0",
  "Jinja2>=3.1",
  "pydantic>=2.0",
]
```

---

## Dôležitý behavior

`fmt` má robiť len canonical rewrite, nie validáciu build systému.

Teda:

```bash
socfw fmt project.yaml --write
socfw validate project.yaml
```

sú dva oddelené kroky.

---

## Definition of Done

Commit 41 je hotový, keď:

* `socfw fmt project.yaml` vypíše canonical YAML
* `socfw fmt project.yaml --write` prepíše súbor
* podporuje project aj timing config
* testy sú green

Ďalší commit:

```text
scaffold: add tested blink/pll/sdram init templates
```
