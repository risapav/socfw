## Commit 52 — path resolution checks pre missing timing / board / IP / CPU files

Cieľ:

* zachytiť chýbajúce cesty skôr a čitateľnejšie
* zlepšiť chyby pri:

  * `timing.file`
  * `project.board_file`
  * `registries.ip`
  * `registries.cpu`
  * `registries.packs`
* dať používateľovi presný path, ktorý neexistuje

Názov commitu:

```text
diagnostics: add path resolution checks for missing timing board ip and cpu files
```

## Pridať

```text
socfw/config/path_checks.py
tests/unit/test_path_checks.py
tests/integration/test_missing_timing_file_diagnostic.py
```

## Upraviť

```text
socfw/config/system_loader.py
socfw/config/project_loader.py
socfw/core/diagnostics.py
```

---

## `socfw/config/path_checks.py`

```python
from __future__ import annotations

from pathlib import Path

from socfw.core.diagnostics import Diagnostic, Severity


def resolve_relative(base_file: str, path: str) -> str:
    p = Path(path).expanduser()
    if p.is_absolute():
        return str(p.resolve())
    return str((Path(base_file).resolve().parent / p).resolve())


def missing_path_diag(*, code: str, file: str, path: str, subject: str, hint: str) -> Diagnostic:
    return Diagnostic(
        code=code,
        severity=Severity.ERROR,
        message=f"Referenced path does not exist: {path}",
        subject=subject,
        file=file,
        hints=(hint,),
    )


def check_existing_file(*, code: str, owner_file: str, ref_path: str, subject: str, hint: str) -> tuple[str, list[Diagnostic]]:
    resolved = resolve_relative(owner_file, ref_path)
    if not Path(resolved).is_file():
        return resolved, [missing_path_diag(code=code, file=owner_file, path=resolved, subject=subject, hint=hint)]
    return resolved, []


def check_existing_dir(*, code: str, owner_file: str, ref_path: str, subject: str, hint: str) -> tuple[str, list[Diagnostic]]:
    resolved = resolve_relative(owner_file, ref_path)
    if not Path(resolved).is_dir():
        return resolved, [missing_path_diag(code=code, file=owner_file, path=resolved, subject=subject, hint=hint)]
    return resolved, []
```

---

## Úprava `SystemLoader`

Pri `timing.file`:

```python
from socfw.config.path_checks import check_existing_file, check_existing_dir, resolve_relative
```

Namiesto implicitného:

```python
timing_path = project_path.parent / "timing_config.yaml"
```

použi prioritu:

```python
timing = None
timing_file_ref = None

if isinstance(project.raw.get("timing"), dict):
    timing_file_ref = project.raw["timing"].get("file")

if timing_file_ref:
    timing_path, t_diags = check_existing_file(
        code="PATH_TIMING001",
        owner_file=str(project_path),
        ref_path=timing_file_ref,
        subject="project.timing.file",
        hint="Check `timing.file` in project.yaml or create the referenced timing YAML.",
    )
    diags.extend(t_diags)
    if t_diags:
        return Result(diagnostics=diags)
elif (project_path.parent / "timing_config.yaml").exists():
    timing_path = str((project_path.parent / "timing_config.yaml").resolve())
else:
    timing_path = None

if timing_path:
    t = self.timing_loader.load(str(timing_path))
    ...
```

---

## Registries path checks

Pred `CatalogIndexer` / `IpLoader` / `CpuLoader`:

```python
checked_pack_roots = []
for p in pack_roots:
    resolved, p_diags = check_existing_dir(
        code="PATH_PACK001",
        owner_file=str(project_path),
        ref_path=p,
        subject="registries.packs",
        hint="Check the path under `registries.packs`.",
    )
    diags.extend(p_diags)
    if not p_diags:
        checked_pack_roots.append(resolved)

pack_roots = checked_pack_roots
```

Pre IP:

```python
checked_ip_dirs = []
for p in project.registries_ip:
    resolved, p_diags = check_existing_dir(
        code="PATH_IP001",
        owner_file=str(project_path),
        ref_path=p,
        subject="registries.ip",
        hint="Check the path under `registries.ip`.",
    )
    diags.extend(p_diags)
    if not p_diags:
        checked_ip_dirs.append(resolved)

ip_search_dirs = checked_ip_dirs + list(pack_index.ip_dirs)
```

Pre CPU:

```python
checked_cpu_dirs = []
for p in project.registries_cpu:
    resolved, p_diags = check_existing_dir(
        code="PATH_CPU001",
        owner_file=str(project_path),
        ref_path=p,
        subject="registries.cpu",
        hint="Check the path under `registries.cpu`.",
    )
    diags.extend(p_diags)
    if not p_diags:
        checked_cpu_dirs.append(resolved)

cpu_search_dirs = checked_cpu_dirs + list(pack_index.cpu_dirs)
```

Ak chceš fail-fast pri missing registry paths:

```python
if any(d.severity == Severity.ERROR for d in diags):
    return Result(diagnostics=diags)
```

---

## Board file check

Ak `project.board_file` existuje:

```python
if project.board_file:
    resolved_board_file, b_diags = check_existing_file(
        code="PATH_BOARD001",
        owner_file=str(project_path),
        ref_path=project.board_file,
        subject="project.board_file",
        hint="Check `project.board_file` or remove it to resolve board from packs.",
    )
    diags.extend(b_diags)
    if b_diags:
        return Result(diagnostics=diags)
else:
    resolved_board_file = self.board_resolver.resolve(...)
```

---

## `tests/unit/test_path_checks.py`

```python
from pathlib import Path

from socfw.config.path_checks import check_existing_file, check_existing_dir, resolve_relative


def test_resolve_relative_path(tmp_path):
    owner = tmp_path / "project.yaml"
    owner.write_text("", encoding="utf-8")

    resolved = resolve_relative(str(owner), "timing_config.yaml")
    assert resolved == str((tmp_path / "timing_config.yaml").resolve())


def test_check_existing_file_reports_missing(tmp_path):
    owner = tmp_path / "project.yaml"
    owner.write_text("", encoding="utf-8")

    resolved, diags = check_existing_file(
        code="PATH_TEST",
        owner_file=str(owner),
        ref_path="missing.yaml",
        subject="test",
        hint="fix it",
    )

    assert resolved.endswith("missing.yaml")
    assert len(diags) == 1
    assert diags[0].code == "PATH_TEST"


def test_check_existing_dir_ok(tmp_path):
    owner = tmp_path / "project.yaml"
    owner.write_text("", encoding="utf-8")
    d = tmp_path / "ip"
    d.mkdir()

    _, diags = check_existing_dir(
        code="PATH_TEST",
        owner_file=str(owner),
        ref_path="ip",
        subject="test",
        hint="fix it",
    )

    assert diags == []
```

---

## `tests/integration/test_missing_timing_file_diagnostic.py`

```python
from pathlib import Path

from socfw.build.full_pipeline import FullBuildPipeline


def test_missing_timing_file_reports_clear_path_error(tmp_path):
    project = tmp_path / "project.yaml"
    project.write_text(
        """
version: 2
kind: project

project:
  name: bad_timing
  mode: standalone
  board: qmtech_ep4ce55

timing:
  file: missing_timing.yaml

registries:
  packs:
    - packs/builtin
  ip: []
  cpu: []

modules: []
""",
        encoding="utf-8",
    )

    result = FullBuildPipeline().validate(str(project))

    assert not result.ok
    assert any(d.code == "PATH_TIMING001" for d in result.diagnostics)
```

---

## Očakávaný nový výstup

```text
ERROR PATH_TIMING001: Referenced path does not exist: /.../missing_timing.yaml
  at: project.yaml
  hint: Check `timing.file` in project.yaml or create the referenced timing YAML.
```

---

## Definition of Done

Commit 52 je hotový, keď:

* missing timing file má jasnú chybu
* missing board file má jasnú chybu
* missing IP/CPU/pack dir má jasnú chybu
* relatívne cesty sa resolvujú voči `project.yaml`
* testy sú green

Ďalší commit:

```text
validate: add board binding width and direction checks
```
