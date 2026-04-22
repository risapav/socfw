Áno. Tu je **Commit 3 ako file-by-file scaffold**:

# Commit 3 — `ProjectModel` + project loader + system loader + prvé `socfw validate`

Cieľ tohto commitu:

* zaviesť **nový projektový model**
* vedieť načítať **legacy `project_config.yaml`**
* napojiť ho na:

  * built-in board pack
  * board resolver
  * board loader
* mať prvý fungujúci príkaz:

```bash
socfw validate <project_config.yaml>
```

Stále platí:

* legacy build flow nelámeš
* staré generátory ešte nepoužívaš ako nový core
* len buduješ nový loading/validation front-end

---

# Názov commitu

```text
loader: add project model, project loader, and pack-aware system loading
```

---

# 1. Súbory, ktoré pridať

```text
socfw/model/project.py
socfw/model/system.py
socfw/model/source_context.py
socfw/config/project_schema.py
socfw/config/project_loader.py
socfw/config/system_loader.py
socfw/validate/rules/base.py
tests/unit/test_project_loader_new.py
tests/integration/test_system_loader_with_pack_board.py
```

---

# 2. Súbory, ktoré upraviť

```text
socfw/cli/main.py
socfw/catalog/index.py
```

Len minimálne.

---

# 3. `socfw/model/project.py`

Toto je Phase 1 minimum.
Zámerne jednoduché, ale už použiteľné.

```python
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class ProjectModule:
    instance: str
    type_name: str
    params: dict = field(default_factory=dict)
    clocks: dict = field(default_factory=dict)
    bind: dict = field(default_factory=dict)
    raw: dict = field(default_factory=dict)


@dataclass
class ProjectModel:
    name: str
    mode: str
    board_ref: str
    board_file: str | None = None
    registries_packs: list[str] = field(default_factory=list)
    registries_ip: list[str] = field(default_factory=list)
    modules: list[ProjectModule] = field(default_factory=list)
    raw: dict = field(default_factory=dict)
```

---

# 4. `socfw/model/source_context.py`

Toto je malý, ale dôležitý súbor.
Pomôže neskôr pri diagnostics v2.

```python
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class SourceContext:
    project_file: str | None = None
    board_file: str | None = None
    timing_file: str | None = None
    ip_files: dict[str, str] = field(default_factory=dict)
```

---

# 5. `socfw/model/system.py`

Phase 1 minimum:

```python
from __future__ import annotations

from dataclasses import dataclass, field

from socfw.model.board import BoardModel
from socfw.model.project import ProjectModel
from socfw.model.source_context import SourceContext


@dataclass
class SystemModel:
    board: BoardModel
    project: ProjectModel
    timing: object | None = None
    ip_catalog: dict = field(default_factory=dict)
    sources: SourceContext = field(default_factory=SourceContext)
```

Poznámka:
V Commite 3 ešte netlačíme `TimingModel` ani `IpDescriptor` silou do type hintov.
To príde neskôr. Tu chceme len funkčný prvý vertical slice.

---

# 6. `socfw/config/project_schema.py`

Toto je schema pre **nový cieľový tvar**, ale loader bude mať aj legacy compatibility mapping.

```python
from __future__ import annotations

from pydantic import BaseModel, Field


class ProjectModuleSchema(BaseModel):
    instance: str
    type: str
    params: dict = Field(default_factory=dict)
    clocks: dict = Field(default_factory=dict)
    bind: dict = Field(default_factory=dict)


class RegistriesSchema(BaseModel):
    packs: list[str] = Field(default_factory=list)
    ip: list[str] = Field(default_factory=list)


class ProjectMetaSchema(BaseModel):
    name: str
    mode: str
    board: str
    board_file: str | None = None
    output_dir: str | None = None
    debug: bool = False


class ClocksSchema(BaseModel):
    primary: dict | None = None
    generated: list[dict] = Field(default_factory=list)


class ProjectConfigSchema(BaseModel):
    version: int = 2
    kind: str = "project"
    project: ProjectMetaSchema
    registries: RegistriesSchema = Field(default_factory=RegistriesSchema)
    clocks: ClocksSchema = Field(default_factory=ClocksSchema)
    modules: list[ProjectModuleSchema] = Field(default_factory=list)
```

---

# 7. `socfw/config/project_loader.py`

Toto je kľúčový commit súbor.
Musí vedieť:

* nový shape
* legacy `project_config.yaml`

## odporúčanie

Sprav explicitný legacy mapping helper.

```python
from __future__ import annotations

from pathlib import Path

from socfw.config.common import load_yaml_file
from socfw.config.project_schema import ProjectConfigSchema
from socfw.core.diagnostics import Diagnostic, Severity
from socfw.core.result import Result
from socfw.model.project import ProjectModel, ProjectModule


def _legacy_to_project_doc(data: dict) -> dict:
    """
    Best-effort mapping from legacy project_config.yaml style
    to the new ProjectConfigSchema-compatible shape.
    """
    design = data.get("design", {})
    board = data.get("board", {})
    plugins = data.get("plugins", {})
    modules = data.get("modules", [])

    mapped_modules = []
    for m in modules:
        mapped_modules.append({
            "instance": m.get("name") or m.get("instance") or m.get("type") or "u0",
            "type": m.get("type") or m.get("module") or "unknown",
            "params": m.get("params", {}),
            "clocks": m.get("clocks", {}),
            "bind": m.get("bind", {}),
        })

    return {
        "version": 2,
        "kind": "project",
        "project": {
            "name": design.get("name") or design.get("top") or "legacy_project",
            "mode": design.get("type") or "standalone",
            "board": board.get("type") or board.get("name") or "unknown_board",
            "board_file": board.get("file"),
            "output_dir": design.get("output_dir"),
            "debug": bool(design.get("debug", False)),
        },
        "registries": {
            "packs": [],
            "ip": list(plugins.get("ip", [])),
        },
        "clocks": {
            "primary": data.get("clocks", {}).get("primary") if isinstance(data.get("clocks"), dict) else None,
            "generated": data.get("clocks", {}).get("generated", []) if isinstance(data.get("clocks"), dict) else [],
        },
        "modules": mapped_modules,
    }


class ProjectLoader:
    def load(self, path: str) -> Result[ProjectModel]:
        raw = load_yaml_file(path)
        if not raw.ok:
            return Result(diagnostics=raw.diagnostics)

        data = raw.value or {}

        parse_errors = []

        try:
            doc = ProjectConfigSchema.model_validate(data)
        except Exception as exc:
            parse_errors.append(exc)
            try:
                compat = _legacy_to_project_doc(data)
                doc = ProjectConfigSchema.model_validate(compat)
            except Exception as exc2:
                return Result(diagnostics=[
                    Diagnostic(
                        code="PRJ100",
                        severity=Severity.ERROR,
                        message=f"Invalid project YAML: {exc2}",
                        subject="project",
                        file=path,
                    )
                ])

        project = ProjectModel(
            name=doc.project.name,
            mode=doc.project.mode,
            board_ref=doc.project.board,
            board_file=doc.project.board_file,
            registries_packs=list(doc.registries.packs),
            registries_ip=list(doc.registries.ip),
            modules=[
                ProjectModule(
                    instance=m.instance,
                    type_name=m.type,
                    params=dict(m.params),
                    clocks=dict(m.clocks),
                    bind=dict(m.bind),
                    raw=m.model_dump(),
                )
                for m in doc.modules
            ],
            raw=doc.model_dump(),
        )

        diags = []
        if parse_errors:
            diags.append(
                Diagnostic(
                    code="PRJ001",
                    severity=Severity.INFO,
                    message="Project YAML was loaded through legacy compatibility mapping",
                    subject="project",
                    file=path,
                )
            )

        return Result(value=project, diagnostics=diags)
```

---

# 8. `socfw/config/system_loader.py`

Tento súbor spojí:

* project loader
* board resolver
* board loader
* pack index

V Commite 3 ešte nerieš:

* timing loader
* ip loader
* cpu loader

To príde v ďalších commitoch.

```python
from __future__ import annotations

from pathlib import Path

from socfw.catalog.board_resolver import BoardResolver
from socfw.catalog.indexer import CatalogIndexer
from socfw.config.board_loader import BoardLoader
from socfw.config.project_loader import ProjectLoader
from socfw.core.diagnostics import Diagnostic, Severity
from socfw.core.result import Result
from socfw.model.source_context import SourceContext
from socfw.model.system import SystemModel


class SystemLoader:
    def __init__(self) -> None:
        self.project_loader = ProjectLoader()
        self.board_loader = BoardLoader()
        self.catalog_indexer = CatalogIndexer()
        self.board_resolver = BoardResolver()

    def load(self, project_file: str) -> Result[SystemModel]:
        prj = self.project_loader.load(project_file)
        diags = list(prj.diagnostics)
        if not prj.ok or prj.value is None:
            return Result(diagnostics=diags)

        project = prj.value

        builtin_pack_root = str(Path("packs/builtin").resolve())
        pack_roots = list(project.registries_packs)
        if builtin_pack_root not in [str(Path(p).resolve()) for p in pack_roots]:
            pack_roots.append(builtin_pack_root)

        pack_index = self.catalog_indexer.index_packs(pack_roots)

        resolved_board_file = self.board_resolver.resolve(
            board_key=project.board_ref,
            explicit_board_file=project.board_file,
            board_dirs=pack_index.board_dirs,
        )

        if resolved_board_file is None:
            diags.append(
                Diagnostic(
                    code="SYS101",
                    severity=Severity.ERROR,
                    message=f"Unable to resolve board '{project.board_ref}'",
                    subject="project.board",
                    file=project_file,
                    path="project.board",
                    hints=(
                        "Set project.board_file explicitly.",
                        "Or add a pack containing boards/<board>/board.yaml.",
                    ),
                )
            )
            return Result(diagnostics=diags)

        brd = self.board_loader.load(resolved_board_file)
        diags.extend(brd.diagnostics)
        if not brd.ok or brd.value is None:
            return Result(diagnostics=diags)

        system = SystemModel(
            board=brd.value,
            project=project,
            timing=None,
            ip_catalog={},
            sources=SourceContext(
                project_file=str(Path(project_file).resolve()),
                board_file=resolved_board_file,
            ),
        )

        return Result(value=system, diagnostics=diags)
```

---

# 9. `socfw/validate/rules/base.py`

Na prvý krok stačí veľmi malé API.

```python
from __future__ import annotations


class ValidationRule:
    def validate(self, system) -> list:
        return []
```

---

# 10. úprava `socfw/catalog/index.py`

V Commite 2 sme tam mali:

* `pack_roots`
* `board_dirs`
* `ip_dirs`
* `cpu_dirs`

To je OK.
Netreba meniť, ak už to tak máš.

Ak si tam mal menej polí, uprav na:

```python
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class CatalogIndex:
    pack_roots: list[str] = field(default_factory=list)
    board_dirs: list[str] = field(default_factory=list)
    ip_dirs: list[str] = field(default_factory=list)
    cpu_dirs: list[str] = field(default_factory=list)
```

---

# 11. úprava `socfw/cli/main.py`

Teraz pridáme prvý reálny command:

* `validate`

## nahradiť aktuálny skeleton týmto

```python
from __future__ import annotations

import argparse

from socfw import __version__
from socfw.config.system_loader import SystemLoader


def cmd_version(_args) -> int:
    print(__version__)
    return 0


def _print_diags(diags) -> None:
    for d in diags:
        head = f"{d.severity.value.upper()} {d.code}: {d.message}"
        print(head)
        if d.file:
            loc = d.file
            if d.path:
                loc += f" :: {d.path}"
            print(f"  at: {loc}")
        for h in getattr(d, "hints", ()):
            print(f"  hint: {h}")


def cmd_validate(args) -> int:
    loaded = SystemLoader().load(args.project)
    _print_diags(loaded.diagnostics)

    if loaded.ok and loaded.value is not None:
        print(f"OK: project={loaded.value.project.name} board={loaded.value.board.board_id}")
        return 0
    return 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="socfw")
    sub = parser.add_subparsers(dest="command", required=True)

    p_ver = sub.add_parser("version", help="Show version")
    p_ver.set_defaults(func=cmd_version)

    p_val = sub.add_parser("validate", help="Validate project and resolve board")
    p_val.add_argument("project")
    p_val.set_defaults(func=cmd_validate)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
```

---

# 12. `tests/unit/test_project_loader_new.py`

Toto otestuje:

* legacy compatibility mapping
* nový `ProjectModel`

```python
from pathlib import Path

from socfw.config.project_loader import ProjectLoader


def test_legacy_project_config_loads(tmp_path):
    project_file = tmp_path / "project_config.yaml"
    project_file.write_text(
        """
design:
  name: demo
  type: standalone

board:
  type: qmtech_ep4ce55
  file: board_qmtech_ep4ce55.yaml

plugins:
  ip:
    - .

modules:
  - name: blink_test
    type: blink_test
    params:
      CLK_FREQ: 50000000
""",
        encoding="utf-8",
    )

    res = ProjectLoader().load(str(project_file))
    assert res.ok
    assert res.value is not None
    assert res.value.name == "demo"
    assert res.value.board_ref == "qmtech_ep4ce55"
    assert len(res.value.modules) == 1
    assert res.value.modules[0].type_name == "blink_test"
```

---

# 13. `tests/integration/test_system_loader_with_pack_board.py`

Toto je prvý reálny end-to-end loader test.

```python
from pathlib import Path

from socfw.config.system_loader import SystemLoader


def test_system_loader_resolves_builtin_board_from_legacy_project(tmp_path):
    project_file = tmp_path / "project_config.yaml"
    project_file.write_text(
        """
design:
  name: demo
  type: standalone

board:
  type: qmtech_ep4ce55

plugins:
  ip:
    - .

modules: []
""",
        encoding="utf-8",
    )

    loaded = SystemLoader().load(str(project_file))
    assert loaded.ok
    assert loaded.value is not None
    assert loaded.value.project.name == "demo"
    assert loaded.value.board.board_id == "qmtech_ep4ce55"
    assert loaded.value.sources.board_file is not None
```

Toto je super, lebo overí:

* legacy project config
* built-in board pack fallback
* board resolver
* board loader
* system loader

---

# 14. Čo v tomto commite ešte **nerobiť**

Vedome by som nechal bokom:

* `ip_loader.py`
* `timing_loader.py`
* `build/full_pipeline.py`
* `socfw build`
* generovanie artefaktov

Commit 3 má vyriešiť len:

* `validate`
* project → board resolution → system model

To je správny scope.

---

# 15. Čo po Commit 3 overiť

Spusti:

```bash
pip install -e .
socfw validate project_config.yaml
pytest tests/unit/test_project_loader_new.py
pytest tests/integration/test_system_loader_with_pack_board.py
```

### očakávanie

* CLI funguje
* project loader funguje
* board sa resolvuje cez `packs/builtin`

Ak máš v koreňovom `project_config.yaml` rozumné legacy polia, `socfw validate project_config.yaml` by už malo aspoň prejsť loading vrstvou.

---

# 16. Ak `project_config.yaml` v tvojom repo vyzerá trochu inak

Najpravdepodobnejšie riziko v Commite 3 je to, že legacy `project_config.yaml` bude mať:

* iné názvy kľúčov
* moduly pod iným menom
* trochu iné `board`/`plugins` shape

To je v poriadku.

### riešenie

Rozšír len `_legacy_to_project_doc()`.

To je presne miesto, kde má byť Phase 1 kompatibilita sústredená.

Nepchaj compatibility logiku do:

* modelov
* CLI
* system loadera

len do:

* `project_loader.py`

To je veľmi dôležité.

---

# 17. Čo má byť Commit 4

Hneď po tomto by som spravil:

## Commit 4

```text
loader: add ip model, ip loader, and pack-aware ip catalog loading
```

Ten prinesie:

* `IpDescriptor`
* `ip_loader.py`
* napojenie `registries.ip`
* prvé načítanie `clkpll.ip.yaml`
* prvé `system.ip_catalog`

A to bude prvý bod, kde sa nový flow začne približovať reálnemu buildu.

---

# 18. Môj praktický odporúčaný postup

Po Commite 3 by som spravil presne toto:

1. `socfw validate` spustiť na reálny legacy `project_config.yaml`
2. ak spadne, upraviť iba `_legacy_to_project_doc()`
3. nezachádzať ďalej, kým validate nefunguje
4. až potom Commit 4

To je najzdravší convergence rytmus.

Ak chceš, ďalšia správa môže byť presne:
👉 **Commit 4 ako file-by-file scaffold: `IpDescriptor` + `ip_loader.py` + pack-aware IP catalog loading**
