Áno. Tu je **Commit 2 ako file-by-file scaffold**:

# Commit 2 — built-in board pack + board loader + board resolver

Cieľ tohto commitu:

* dostať **shared board** do nového sveta
* zaviesť **prvý reálny pack**
* mať **nový BoardModel**
* vedieť načítať board:

  * buď z explicitného `board_file`
  * alebo z `packs/builtin`

Tento commit je stále bezpečný:

* legacy flow neláme
* staré build skripty nemení
* len pridáva nový converged základ

---

# Názov commitu

```text
catalog: add builtin board pack, board model, and board loader
```

---

# 1. Súbory, ktoré pridať

```text
socfw/model/board.py
socfw/catalog/index.py
socfw/catalog/indexer.py
socfw/catalog/board_resolver.py
socfw/config/board_schema.py
socfw/config/board_loader.py

packs/builtin/pack.yaml
packs/builtin/boards/qmtech_ep4ce55/board.yaml

tests/unit/test_board_loader_new.py
tests/integration/test_pack_board_resolution.py
```

---

# 2. `socfw/model/board.py`

Phase 1 minimum, ale už použiteľné aj pre SDRAM resource model neskôr.

```python
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class BoardPin:
    pin: str


@dataclass(frozen=True)
class BoardPinVector:
    pins: tuple[str, ...]


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
class BoardResource:
    kind: str                     # scalar / vector / inout
    top_name: str
    width: int = 1
    pin: str | None = None
    pins: tuple[str, ...] = ()


@dataclass
class BoardModel:
    board_id: str
    system_clock: BoardClock
    system_reset: BoardReset | None = None
    fpga_family: str | None = None
    fpga_part: str | None = None
    resources: dict[str, object] = field(default_factory=dict)
```

---

# 3. `socfw/catalog/index.py`

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

# 4. `socfw/catalog/indexer.py`

Toto zatiaľ rieši len najnutnejšie.

```python
from __future__ import annotations

from pathlib import Path

from socfw.catalog.index import CatalogIndex


class CatalogIndexer:
    def index_packs(self, roots: list[str]) -> CatalogIndex:
        idx = CatalogIndex()

        for root in roots:
            rp = Path(root).expanduser().resolve()
            if not rp.exists():
                continue

            idx.pack_roots.append(str(rp))

            boards = rp / "boards"
            ip = rp / "ip"
            cpu = rp / "cpu"

            if boards.exists():
                idx.board_dirs.append(str(boards))
            if ip.exists():
                idx.ip_dirs.append(str(ip))
            if cpu.exists():
                idx.cpu_dirs.append(str(cpu))

        return idx
```

---

# 5. `socfw/catalog/board_resolver.py`

Toto je veľmi dôležitý súbor.
Politika je jednoduchá a správna:

1. explicit `board_file`
2. pack lookup

```python
from __future__ import annotations

from pathlib import Path


class BoardResolver:
    def resolve(
        self,
        *,
        board_key: str,
        explicit_board_file: str | None,
        board_dirs: list[str],
    ) -> str | None:
        if explicit_board_file:
            p = Path(explicit_board_file).expanduser().resolve()
            if p.exists():
                return str(p)

        for d in board_dirs:
            candidate = Path(d) / board_key / "board.yaml"
            if candidate.exists():
                return str(candidate.resolve())

        return None
```

---

# 6. `socfw/config/board_schema.py`

Tu odporúčam urobiť nový schema kontrakt, ale zároveň loader nech vie spracovať aj starší tvar.

```python
from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field


class BoardClockSchema(BaseModel):
    id: str
    top_name: str
    pin: str
    frequency_hz: int


class BoardResetSchema(BaseModel):
    id: str
    top_name: str
    pin: str
    active_low: bool = True


class BoardResourceScalarSchema(BaseModel):
    kind: Literal["scalar"]
    top_name: str
    pin: str


class BoardResourceVectorSchema(BaseModel):
    kind: Literal["vector", "inout"]
    top_name: str
    width: int
    pins: list[str]


class BoardFpgaSchema(BaseModel):
    family: str | None = None
    part: str | None = None


class BoardSystemSchema(BaseModel):
    clock: BoardClockSchema
    reset: BoardResetSchema | None = None


class BoardConfigSchema(BaseModel):
    version: int = 2
    kind: str = "board"
    board: dict
    fpga: BoardFpgaSchema = Field(default_factory=BoardFpgaSchema)
    system: BoardSystemSchema
    resources: dict = Field(default_factory=dict)
```

Poznámka:
Tu som nechal `resources: dict`, lebo tvoj existujúci board YAML je bohatý a nechcem v Commite 2 zabiť čas príliš prísnym schema parserom. Presnejší schema model môže prísť v ďalšom kroku.

---

# 7. `socfw/config/board_loader.py`

Toto je najdôležitejší nový súbor v Commite 2.

Loader má:

* načítať YAML
* overiť základný shape
* vyrobiť `BoardModel`

```python
from __future__ import annotations

from socfw.config.board_schema import BoardConfigSchema
from socfw.config.common import load_yaml_file
from socfw.core.diagnostics import Diagnostic, Severity
from socfw.core.result import Result
from socfw.model.board import BoardClock, BoardModel, BoardReset


class BoardLoader:
    def load(self, path: str) -> Result[BoardModel]:
        raw = load_yaml_file(path)
        if not raw.ok:
            return Result(diagnostics=raw.diagnostics)

        data = raw.value or {}

        try:
            doc = BoardConfigSchema.model_validate(data)
        except Exception as exc:
            return Result(diagnostics=[
                Diagnostic(
                    code="BRD100",
                    severity=Severity.ERROR,
                    message=f"Invalid board YAML: {exc}",
                    subject="board",
                    file=path,
                )
            ])

        board_id = str(doc.board.get("id") or doc.board.get("name") or "unknown")

        model = BoardModel(
            board_id=board_id,
            system_clock=BoardClock(
                id=doc.system.clock.id,
                top_name=doc.system.clock.top_name,
                pin=doc.system.clock.pin,
                frequency_hz=doc.system.clock.frequency_hz,
            ),
            system_reset=(
                BoardReset(
                    id=doc.system.reset.id,
                    top_name=doc.system.reset.top_name,
                    pin=doc.system.reset.pin,
                    active_low=doc.system.reset.active_low,
                )
                if doc.system.reset is not None else None
            ),
            fpga_family=doc.fpga.family,
            fpga_part=doc.fpga.part,
            resources=dict(doc.resources),
        )

        return Result(value=model)
```

---

# 8. `packs/builtin/pack.yaml`

```yaml
version: 1
kind: pack
name: builtin
title: Built-in socfw pack
provides:
  - boards
```

---

# 9. `packs/builtin/boards/qmtech_ep4ce55/board.yaml`

Toto má byť v Commite 2 **takmer priama kópia** z tvojho existujúceho `board_qmtech_ep4ce55.yaml`, ale mierne uprataná, ak treba.

Ak chceš minimálne riziko, sprav presne toto:

* skopíruj existujúci `board_qmtech_ep4ce55.yaml`
* len uisti sa, že obsahuje:

  * `board.id`
  * `fpga`
  * `system.clock`
  * `system.reset`
  * `resources`

Ak v starom súbore už toto je, nič nevymýšľaj.

### Dôležité

V Commite 2 by som ešte **needitoval obsah board resource stromu**, pokiaľ loader vie prejsť základ.
Nechaj maximum z pôvodného board file tak, ako je, lebo je to overený asset.

---

# 10. `tests/unit/test_board_loader_new.py`

Tento test má overiť:

* nový board loader funguje
* built-in pack board file je validný

```python
from socfw.config.board_loader import BoardLoader


def test_builtin_board_loads():
    res = BoardLoader().load("packs/builtin/boards/qmtech_ep4ce55/board.yaml")
    assert res.ok
    assert res.value is not None
    assert res.value.board_id == "qmtech_ep4ce55"
    assert res.value.system_clock.top_name
    assert res.value.system_clock.frequency_hz > 0
```

Ak sa tvoj board id v starom YAML volá inak, uprav assertion podľa reality.

---

# 11. `tests/integration/test_pack_board_resolution.py`

Toto už testuje pack resolution politiku.

```python
from socfw.catalog.board_resolver import BoardResolver
from socfw.catalog.indexer import CatalogIndexer


def test_builtin_board_resolves_from_pack():
    idx = CatalogIndexer().index_packs(["packs/builtin"])
    resolved = BoardResolver().resolve(
        board_key="qmtech_ep4ce55",
        explicit_board_file=None,
        board_dirs=idx.board_dirs,
    )

    assert resolved is not None
    assert resolved.endswith("packs/builtin/boards/qmtech_ep4ce55/board.yaml")
```

---

# 12. Čo v tomto commite ešte **neupravovať**

Zámerne by som sa ešte nedotýkal:

* `project_loader.py`
* `system_loader.py`
* `ip_loader.py`
* `rtl_builder.py`
* `project_config.yaml`

Lebo Commit 2 má riešiť len:

* board pack
* board model
* board loader
* board resolution

To je zdravý scope.

---

# 13. Čo po Commit 2 overiť

Spusti:

```bash
pip install -e .
pytest tests/unit/test_board_loader_new.py
pytest tests/integration/test_pack_board_resolution.py
```

Očakávanie:

* všetko green

A manuálne si vieš skúsiť v Python REPL:

```python
from socfw.catalog.indexer import CatalogIndexer
from socfw.catalog.board_resolver import BoardResolver

idx = CatalogIndexer().index_packs(["packs/builtin"])
print(idx.board_dirs)
print(BoardResolver().resolve(board_key="qmtech_ep4ce55", explicit_board_file=None, board_dirs=idx.board_dirs))
```

---

# 14. Ak sa zasekneš na existujúcom board YAML

Najpravdepodobnejšie riziko v Commite 2 je, že tvoj aktuálny `board_qmtech_ep4ce55.yaml` nebude 1:1 sedieť na nový schema tvar.

V tom prípade odporúčam tento fallback:

## fallback politika

V `board_loader.py` sprav:

* najprv pokus o nový schema parse
* ak zlyhá, sprav **legacy compatibility mapping**

Napríklad:

```python
def _legacy_to_board_doc(data: dict) -> dict:
    # map old board yaml shape to new minimal shape
    ...
```

A potom:

```python
try:
    doc = BoardConfigSchema.model_validate(data)
except Exception:
    data2 = _legacy_to_board_doc(data)
    doc = BoardConfigSchema.model_validate(data2)
```

To je veľmi praktické a v súlade s convergence stratégiou.

---

# 15. Čo má byť Commit 3

Hneď po tomto by som spravil:

## Commit 3

```text
loader: add project model, project loader, and pack-aware system loading
```

Ten už prinesie:

* `ProjectModel`
* `project_loader.py`
* `system_loader.py`
* `SourceContext`
* napojenie board resolvera na projekt

A to bude prvý bod, kde vieš spraviť:

* `socfw validate <project>`

---

# 16. Môj praktický odporúčaný postup

Takto by som to robil presne:

### Commit 1

package skeleton

### Commit 2

board pack + board loader

### hneď potom overenie

* install
* unit
* integration

### až potom Commit 3

project loader + system loader

To je nízke riziko a dobrý rytmus.

Ak chceš, ďalšia správa môže byť presne:
👉 **Commit 3 ako file-by-file scaffold: ProjectModel + project loader + system loader + prvé `socfw validate`**
