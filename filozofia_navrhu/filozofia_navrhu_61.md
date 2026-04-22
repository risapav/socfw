Áno. Tu je **Phase 1 ako patch plan** — čo presne **pridať**, čo **minimálne upraviť** a v akom poradí, aby si dostal nový core do existujúceho repa s čo najmenším rizikom.

Budem sa držať tvojho aktuálneho stavu v `/mnt/data`:

* existujúce kľúčové súbory:

  * `base.py`
  * `rtl_builder.py`
  * `rtl.py`
  * `tcl.py`
  * `sdc.py`
  * `sw.py`
  * `board_qmtech_ep4ce55.yaml`
  * `project_config.yaml`
  * `timing_config.yaml`
  * `clkpll.ip.yaml`
  * `sdram_fifo.ip.yaml`

Cieľ Phase 1:

* nový `socfw/` core existuje
* vie načítať legacy configy
* vie spraviť aspoň **validate + stable blink build path**
* shared board ide cez pack
* starý flow ostáva fallback

---

# Patch plan — prehľad

Rozdelím to na 4 skupiny:

1. **Nové súbory**
2. **Minimálne editácie existujúcich súborov**
3. **Prvé fixture migrácie**
4. **Checkpoint testy**

---

# 1. Nové súbory

Toto by som pridal hneď v prvej vlne.

---

## 1.1 Package skeleton

### pridať

```text
socfw/
  __init__.py
  cli/
    main.py
  core/
    diagnostics.py
    result.py
  emit/
    renderer.py
  config/
    common.py
    board_schema.py
    project_schema.py
    ip_schema.py
    timing_schema.py
    board_loader.py
    project_loader.py
    ip_loader.py
    timing_loader.py
    system_loader.py
  model/
    board.py
    project.py
    ip.py
    timing.py
    system.py
    source_context.py
  validate/
    __init__.py
    rules/
      __init__.py
      base.py
      board_rules.py
      project_rules.py
  build/
    context.py
    pipeline.py
    full_pipeline.py
  catalog/
    index.py
    indexer.py
    board_resolver.py
```

---

## 1.2 Built-in board pack

### pridať

```text
packs/
  builtin/
    pack.yaml
    boards/
      qmtech_ep4ce55/
        board.yaml
```

### obsah

* `packs/builtin/boards/qmtech_ep4ce55/board.yaml`

  * zatiaľ skoro čistá kópia z `board_qmtech_ep4ce55.yaml`
* `packs/builtin/pack.yaml`

```yaml
version: 1
kind: pack
name: builtin
title: Built-in socfw pack
provides:
  - boards
```

---

## 1.3 Pyproject

### pridať alebo upraviť

`pyproject.toml`

minimum:

```toml
[build-system]
requires = ["setuptools>=68", "wheel"]
build-backend = "setuptools.build_meta"

[tool.setuptools.packages.find]
include = ["socfw*"]

[tool.setuptools.package-data]
socfw = ["templates/*.j2"]

[project]
name = "socfw"
version = "0.1.0"
requires-python = ">=3.11"

[project.scripts]
socfw = "socfw.cli.main:main"
```

---

# 2. Minimálne editácie existujúcich súborov

Tu je dôležité: čo najmenej rozbíjať.

---

## 2.1 `base.py`

### cieľ

Nepoužívať ho ako budúce jadro, ale vyťažiť z neho renderer.

### sprav

* **nič v ňom zatiaľ nelám**
* skopíruj jeho použiteľnú časť do:

  * `socfw/emit/renderer.py`

### nový `socfw/emit/renderer.py`

Prenes z `base.py`:

* Jinja env setup
* render helper
* write helper

### minimálna úprava v `base.py`

Žiadna povinná. Môže zostať.

---

## 2.2 `board_qmtech_ep4ce55.yaml`

### cieľ

Spraviť z neho source pre built-in pack

### sprav

* **nemeníť pôvodný súbor**
* skopíruj ho do:

  * `packs/builtin/boards/qmtech_ep4ce55/board.yaml`

### prečo

Tým nezlomíš nič staré a nový flow už môže ísť z packu.

---

## 2.3 `project_config.yaml`

### cieľ

Zatiaľ neprepisovať ručne všetky projekty

### sprav

* **nemeníť súbor**
* nový `project_loader.py` nech vie načítať legacy shape

### compatibility mapping, ktorý musíš spraviť

Legacy:

```yaml
design:
  top: ...
plugins:
  ip: ...
board:
  type: ...
  file: ...
modules: ...
```

Nový loader to premapuje na interný `ProjectModel`.

### dôležité

Toto je kľúčový patch, ktorý ti ušetrí hromadný edit existujúcich projektov.

---

## 2.4 `timing_config.yaml`

### cieľ

Zachovať ako asset, ale načítavať typed loaderom

### sprav

* bez zmeny súboru
* nový `timing_loader.py` nech vie parse-núť aktuálny shape

---

## 2.5 `clkpll.ip.yaml`

### cieľ

Použiť ho zatiaľ ako legacy-loadable IP descriptor

### sprav

* bez zmeny súboru v Phase 1
* nový `ip_loader.py` nech vie legacy shape

### poznámka

Do Phase 1 ho ešte nemusíš preklopiť na nový vendor model. To príde v ďalšej fáze.

---

## 2.6 `rtl_builder.py`

### cieľ

Nevstupovať doň agresívne

### sprav

* v Phase 1 **bez editácie**, ak sa dá
* nový flow ho nemá používať ako core
* môže slúžiť ako referencia

### výnimka

Ak potrebuješ dočasný compatibility wrapper, sprav nový súbor:

* `socfw/build/legacy_bridge.py`

a ten nech volá starý generator.

**Needituj Phase 1 jadro priamo do `rtl_builder.py`.**

---

## 2.7 `rtl.py`, `tcl.py`, `sdc.py`, `sw.py`

### cieľ

Použiť len ako dočasné emit backendy alebo referenciu

### Phase 1 odporúčanie

* priamo ich ešte neprepisovať
* nový pipeline ich môže obaliť cez adapter vrstvu

Ak musíš niečo editovať, tak len:

* odstrániť alebo minimalizovať `print(...)`
* aby sa dali volať tichšie z nového orchestration layer

### ak chceš minimal patch

Sprav v nich:

* voliteľný parameter `quiet: bool = True`
* a `print()` len ak `quiet is False`

To je dobrý malý patch.

---

# 3. Presný obsah nových súborov — minimum pre Phase 1

Tu je minimálny implementačný obsah, nie plná finálna architektúra.

---

## 3.1 `socfw/core/result.py`

```python
from dataclasses import dataclass, field
from typing import Generic, TypeVar

T = TypeVar("T")

@dataclass
class Result(Generic[T]):
    value: T | None = None
    diagnostics: list = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not any(getattr(d, "severity", None) == "error" or getattr(getattr(d, "severity", None), "value", None) == "error" for d in self.diagnostics)
```

---

## 3.2 `socfw/core/diagnostics.py`

Minimum:

```python
from dataclasses import dataclass, field
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

Phase 1 nepotrebuje plný v2 model, ale aspoň toto.

---

## 3.3 `socfw/config/common.py`

```python
from pathlib import Path
import yaml

from socfw.core.result import Result
from socfw.core.diagnostics import Diagnostic, Severity


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
        data = yaml.safe_load(p.read_text(encoding="utf-8")) or {}
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

    return Result(value=data)
```

---

## 3.4 `socfw/model/board.py`

Drž to jednoduché. Phase 1 minimum:

```python
from dataclasses import dataclass, field


@dataclass
class BoardClock:
    id: str
    top_name: str
    pin: str
    frequency_hz: int


@dataclass
class BoardReset:
    id: str
    top_name: str
    pin: str
    active_low: bool = True


@dataclass
class BoardModel:
    board_id: str
    system_clock: BoardClock
    system_reset: BoardReset | None = None
    resources: dict = field(default_factory=dict)
    fpga: dict = field(default_factory=dict)
```

---

## 3.5 `socfw/model/project.py`

```python
from dataclasses import dataclass, field


@dataclass
class ProjectModule:
    instance: str
    type_name: str
    params: dict = field(default_factory=dict)
    clocks: dict = field(default_factory=dict)
    bind: dict = field(default_factory=dict)


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

## 3.6 `socfw/model/ip.py`

Phase 1 minimum:

```python
from dataclasses import dataclass, field


@dataclass
class IpDescriptor:
    name: str
    module: str
    category: str
    synthesis_files: tuple[str, ...] = ()
    metadata_files: tuple[str, ...] = ()
    raw: dict = field(default_factory=dict)
```

---

## 3.7 `socfw/model/timing.py`

```python
from dataclasses import dataclass, field


@dataclass
class TimingModel:
    generated_clocks: list[dict] = field(default_factory=list)
    false_paths: list[dict] = field(default_factory=list)
    raw: dict = field(default_factory=dict)
```

---

## 3.8 `socfw/model/system.py`

```python
from dataclasses import dataclass, field

from socfw.model.board import BoardModel
from socfw.model.project import ProjectModel
from socfw.model.timing import TimingModel
from socfw.model.ip import IpDescriptor


@dataclass
class SystemModel:
    board: BoardModel
    project: ProjectModel
    timing: TimingModel | None
    ip_catalog: dict[str, IpDescriptor] = field(default_factory=dict)
```

---

# 4. Loader diffy — kde je jadro Phase 1

Toto je najdôležitejší patch.

---

## 4.1 `socfw/config/board_loader.py`

### patch cieľ

Vie načítať:

* starý `board_qmtech_ep4ce55.yaml`
* nový pack board

### minimálna implementácia

Mapuj:

* `board.id`
* `system.clock`
* `system.reset`
* `resources`
* `fpga`

Ak starý board súbor používa trochu inú štruktúru, sprav compatibility mapping vnútri loadera.

---

## 4.2 `socfw/config/project_loader.py`

### patch cieľ

Vie načítať starý `project_config.yaml`

### compatibility mapping

Z legacy na `ProjectModel`:

* `design.name` → `project.name`
* `design.type` → `project.mode`
* `board.type` → `board_ref`
* `board.file` → `board_file`
* `plugins.ip` → `registries_ip`
* `modules[]` → `ProjectModule[]`

Toto je najkritickejší compatibility patch celej Phase 1.

---

## 4.3 `socfw/config/ip_loader.py`

### patch cieľ

Vie načítať:

* `*.ip.yaml`
* normalizovať artifact paths relatívne k descriptoru

### minimum

Zober:

* `ip.name`
* `ip.module`
* `ip.type` alebo category ekvivalent
* `files`

a premapuj na `IpDescriptor`.

---

## 4.4 `socfw/config/timing_loader.py`

### patch cieľ

Vie načítať `timing_config.yaml`

### minimum

Zober:

* generated clocks
* false paths / extra timing directives
* raw store

---

## 4.5 `socfw/catalog/indexer.py` + `board_resolver.py`

### patch cieľ

`project.board` vie nájsť board v `packs/builtin`

### Phase 1 policy

* explicit `board_file` vyhráva
* inak hľadaj v `registries.packs`
* zatiaľ len `boards/<board>/board.yaml`

---

## 4.6 `socfw/config/system_loader.py`

### patch cieľ

Poskladá:

* project
* board
* timing
* ip catalog

a vráti `SystemModel`.

Toto je prvý veľký green checkpoint.

---

# 5. Pipeline a CLI — minimálny Phase 1 build

---

## 5.1 `socfw/build/context.py`

```python
from dataclasses import dataclass

@dataclass
class BuildRequest:
    project_file: str
    out_dir: str
```

---

## 5.2 `socfw/build/pipeline.py`

Phase 1 minimum:

* load system
* run validate
* zatiaľ len vráť system + diagnostics

Nemusí ešte mať full IR pipeline.

---

## 5.3 `socfw/build/full_pipeline.py`

Tu môžeš mať dočasný bridge:

* nový loader/validate
* starý emit backend

Teda:

* nový world rozhoduje vstupy
* starý world ešte dočasne generuje výstupy

To je najbezpečnejší convergence pattern.

---

## 5.4 `socfw/cli/main.py`

Minimum:

```python
def main():
    ...
```

Podpor:

* `socfw validate <project>`
* `socfw build <project> --out build/gen`

Ak Phase 1 build ešte interne používa legacy emit, je to úplne v poriadku.

---

# 6. Prvé konkrétne fixture migrácie

Tu odporúčam len 2 malé zmeny.

---

## 6.1 nový fixture: pack-aware blink

Nerob hneď edit pôvodného `project_config.yaml`.

Sprav radšej nový fixture, napr.:

```text
tests/golden/fixtures/blink_converged/project.yaml
```

a tam už použi nový shape:

* `project.board`
* `registries.packs`

To ti dá čistý test nového flow bez rozbíjania starého.

---

## 6.2 starý `blink_test_01` nech zatiaľ ostane

Nech Phase 1 loader vie načítať legacy config, ale nové green coverage si buduj cez nový converged fixture.

To výrazne zníži riziko.

---

# 7. Presný TODO list — čo spraviť v poradí

Toto je podľa mňa najlepší implementačný sled.

---

## Krok 1

Pridať:

* `socfw/`
* `pyproject.toml`
* `socfw/emit/renderer.py`

## Krok 2

Pridať:

* `core/result.py`
* `core/diagnostics.py`
* `config/common.py`

## Krok 3

Pridať:

* `model/board.py`
* `model/project.py`
* `model/ip.py`
* `model/timing.py`
* `model/system.py`

## Krok 4

Pridať:

* `board_loader.py`
* `project_loader.py`
* `ip_loader.py`
* `timing_loader.py`
* `system_loader.py`

## Krok 5

Pridať:

* `packs/builtin/.../board.yaml`

## Krok 6

Pridať:

* `catalog/indexer.py`
* `catalog/board_resolver.py`

## Krok 7

Pridať:

* `build/context.py`
* `build/pipeline.py`
* `build/full_pipeline.py`
* `cli/main.py`

## Krok 8

Pridať:

* nový pack-aware blink fixture
* integration test na load + build

---

# 8. Čo je minimum “green” pre Phase 1

Phase 1 je hotová, keď:

* `pip install -e .` funguje
* `socfw validate <legacy project_config.yaml>` funguje
* `socfw validate <new pack-aware blink fixture>` funguje
* `socfw build <new pack-aware blink fixture>` vygeneruje artefakty
* board sa resolvuje z `packs/builtin`
* starý flow ešte stále nepadá

---

# 9. Čo by som ti odporučil ako úplne prvý commit

Ak chceš úplne najmenší bezpečný štart, sprav najprv len toto:

## Commit A

* `pyproject.toml`
* `socfw/__init__.py`
* `socfw/emit/renderer.py`
* `socfw/core/result.py`
* `socfw/core/diagnostics.py`
* `socfw/config/common.py`

Potom hneď:

## Commit B

* `packs/builtin/boards/qmtech_ep4ce55/board.yaml`
* `catalog/indexer.py`
* `catalog/board_resolver.py`
* `board_loader.py`

Až potom:

## Commit C

* `project_loader.py`
* `system_loader.py`
* `cli/main.py`

To je najnižšie riziko.

---

# 10. Môj praktický záver

Ak to zhrniem úplne pragmaticky:

## v tomto repozitári by som Phase 1 robil takto:

* **nič veľké neprepisovať**
* **nechať staré build súbory žiť**
* najprv zaviesť:

  * nový loader
  * nový model
  * nový board pack
  * nový CLI
* build zatiaľ môže používať legacy backend wrapper

To je správny convergence pattern.

Ak chceš, v ďalšej správe ti môžem dať ešte presnejšie:

👉 **Commit 1 ako konkrétny file-by-file scaffold s minimálnym obsahom každého nového súboru**.
