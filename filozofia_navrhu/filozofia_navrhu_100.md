## Commit 36 — canonical YAML kontrakt + aliasy

Cieľ:

* zafixovať oficiálny formát
* akceptovať staršie/alternatívne tvary
* dávať zrozumiteľné warningy
* zabrániť chybám typu `timing.config` vs `timing.file`

Názov commitu:

```text
config: add canonical schema docs and compatibility aliases
```

## Pridať

```text
docs/schema/project_v2.md
docs/schema/timing_v2.md
socfw/config/aliases.py
tests/unit/test_project_aliases.py
tests/unit/test_timing_aliases.py
```

## Upraviť

```text
socfw/config/project_loader.py
socfw/config/timing_loader.py
socfw/core/diagnostics.py
```

---

## `docs/schema/project_v2.md`

````md
# Project schema v2

Canonical project file shape:

```yaml
version: 2
kind: project

project:
  name: my_project
  mode: standalone
  board: qmtech_ep4ce55
  board_file: optional/path/to/board.yaml
  debug: true

timing:
  file: timing_config.yaml

registries:
  packs: []
  ip: []
  cpu: []

clocks:
  primary:
    domain: sys_clk
    source: board:SYS_CLK
    frequency_hz: 50000000
  generated: []

modules:
  - instance: blink_test
    type: blink_test
````

Deprecated aliases accepted with warning:

| Deprecated           | Canonical            |
| -------------------- | -------------------- |
| `timing.config`      | `timing.file`        |
| `paths.ip_plugins`   | `registries.ip`      |
| `board.type`         | `project.board`      |
| `board.file`         | `project.board_file` |
| dict-style `modules` | list-style `modules` |

````

---

## `docs/schema/timing_v2.md`

```md
# Timing schema v2

Canonical timing file shape:

```yaml
version: 2
kind: timing

timing:
  clocks:
    - name: SYS_CLK
      port: SYS_CLK
      period_ns: 20.0
      reset:
        port: RESET_N
        active_low: true
        sync_stages: 2

  io_delays:
    auto: true
    clock: SYS_CLK
    default_input_max_ns: 3.0
    default_output_max_ns: 3.0

  false_paths:
    - from_port: RESET_N
      comment: Async reset
````

Deprecated aliases accepted with warning:

| Deprecated              | Canonical            |
| ----------------------- | -------------------- |
| top-level `clocks`      | `timing.clocks`      |
| top-level `io_delays`   | `timing.io_delays`   |
| top-level `false_paths` | `timing.false_paths` |

````

---

## `socfw/config/aliases.py`

```python
from __future__ import annotations

from copy import deepcopy

from socfw.core.diagnostics import Diagnostic, Severity


def alias_warning(code: str, file: str, old: str, new: str) -> Diagnostic:
    return Diagnostic(
        code=code,
        severity=Severity.WARNING,
        message=f"Deprecated config alias `{old}` used; prefer `{new}`",
        subject="config.alias",
        file=file,
        hints=(f"Replace `{old}` with `{new}`.",),
    )


def normalize_project_aliases(data: dict, *, file: str) -> tuple[dict, list[Diagnostic]]:
    d = deepcopy(data)
    diags: list[Diagnostic] = []

    # timing.config -> timing.file
    timing = d.get("timing")
    if isinstance(timing, dict) and "config" in timing and "file" not in timing:
        timing["file"] = timing["config"]
        diags.append(alias_warning("PRJ_ALIAS001", file, "timing.config", "timing.file"))

    # legacy paths.ip_plugins -> registries.ip
    paths = d.get("paths")
    if isinstance(paths, dict) and "ip_plugins" in paths:
        d.setdefault("registries", {})
        if "ip" not in d["registries"]:
            d["registries"]["ip"] = list(paths.get("ip_plugins") or [])
            diags.append(alias_warning("PRJ_ALIAS002", file, "paths.ip_plugins", "registries.ip"))

    # legacy board.type/file -> project.board/project.board_file
    board = d.get("board")
    if isinstance(board, dict):
        d.setdefault("project", {})
        if "type" in board and "board" not in d["project"]:
            d["project"]["board"] = board["type"]
            diags.append(alias_warning("PRJ_ALIAS003", file, "board.type", "project.board"))
        if "file" in board and "board_file" not in d["project"]:
            d["project"]["board_file"] = board["file"]
            diags.append(alias_warning("PRJ_ALIAS004", file, "board.file", "project.board_file"))

    # legacy design.name/mode -> project.name/mode
    design = d.get("design")
    if isinstance(design, dict):
        d.setdefault("project", {})
        if "name" in design and "name" not in d["project"]:
            d["project"]["name"] = design["name"]
            diags.append(alias_warning("PRJ_ALIAS005", file, "design.name", "project.name"))
        if "mode" in design and "mode" not in d["project"]:
            d["project"]["mode"] = design["mode"]
            diags.append(alias_warning("PRJ_ALIAS006", file, "design.mode", "project.mode"))

    # dict-style modules -> list-style modules
    modules = d.get("modules")
    if isinstance(modules, dict):
        converted = []
        for inst, spec in modules.items():
            if not isinstance(spec, dict):
                continue
            converted.append({
                "instance": inst,
                "type": spec.get("type") or spec.get("module") or inst,
                "params": spec.get("params", {}),
                "clocks": spec.get("clocks", {}),
                "bind": spec.get("bind", {}),
                "bus": spec.get("bus"),
            })
        d["modules"] = converted
        diags.append(alias_warning("PRJ_ALIAS007", file, "dict-style modules", "list-style modules"))

    return d, diags


def normalize_timing_aliases(data: dict, *, file: str) -> tuple[dict, list[Diagnostic]]:
    d = deepcopy(data)
    diags: list[Diagnostic] = []

    if "timing" not in d:
        timing = {}
        moved = False

        for key in ("clocks", "generated_clocks", "io_delays", "false_paths"):
            if key in d:
                timing[key] = d[key]
                moved = True

        if moved:
            d["timing"] = timing
            diags.append(alias_warning("TIM_ALIAS001", file, "top-level timing keys", "timing.*"))

    return d, diags
````

---

## Úprava `project_loader.py`

V `load()` po načítaní YAML pridaj normalizáciu ešte pred Pydantic validáciou:

```python
from socfw.config.aliases import normalize_project_aliases
```

Potom:

```python
data = raw.value or {}
data, alias_diags = normalize_project_aliases(data, file=path)
```

A pri návrate pridaj diagnostiky:

```python
diags = list(alias_diags)
```

Ak už tam máš legacy mapping info, len ho pridaj za alias warnings.

---

## Úprava `timing_loader.py`

Rovnako:

```python
from socfw.config.aliases import normalize_timing_aliases
```

Po načítaní:

```python
data = raw.value or {}
data, alias_diags = normalize_timing_aliases(data, file=path)
```

A pri návrate:

```python
diags = list(alias_diags)
```

---

## Test: `tests/unit/test_project_aliases.py`

```python
from socfw.config.aliases import normalize_project_aliases


def test_project_alias_timing_config_to_file():
    data, diags = normalize_project_aliases(
        {"timing": {"config": "timing_config.yaml"}},
        file="project.yaml",
    )

    assert data["timing"]["file"] == "timing_config.yaml"
    assert any(d.code == "PRJ_ALIAS001" for d in diags)


def test_project_alias_dict_modules_to_list():
    data, diags = normalize_project_aliases(
        {
            "modules": {
                "blink_test": {
                    "module": "blink_test",
                    "params": {"CLK_FREQ": 50000000},
                }
            }
        },
        file="project.yaml",
    )

    assert isinstance(data["modules"], list)
    assert data["modules"][0]["instance"] == "blink_test"
    assert data["modules"][0]["type"] == "blink_test"
    assert any(d.code == "PRJ_ALIAS007" for d in diags)
```

---

## Test: `tests/unit/test_timing_aliases.py`

```python
from socfw.config.aliases import normalize_timing_aliases


def test_timing_top_level_keys_are_wrapped():
    data, diags = normalize_timing_aliases(
        {
            "version": 2,
            "kind": "timing",
            "clocks": [{"name": "SYS_CLK"}],
            "false_paths": [{"from_port": "RESET_N"}],
        },
        file="timing_config.yaml",
    )

    assert "timing" in data
    assert data["timing"]["clocks"][0]["name"] == "SYS_CLK"
    assert data["timing"]["false_paths"][0]["from_port"] == "RESET_N"
    assert any(d.code == "TIM_ALIAS001" for d in diags)
```

---

## Výsledok

Po tomto commite by ti mali prejsť oba tvary:

```yaml
timing:
  file: timing_config.yaml
```

aj:

```yaml
timing:
  config: timing_config.yaml
```

A timing loader by mal akceptovať aj:

```yaml
clocks:
io_delays:
false_paths:
```

aj canonical:

```yaml
timing:
  clocks:
  io_delays:
  false_paths:
```

Ďalší logický commit:

```text
diagnostics: replace raw pydantic validation errors with actionable schema hints
```
