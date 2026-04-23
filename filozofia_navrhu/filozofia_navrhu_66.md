Áno. Tu je **Commit 5 ako file-by-file scaffold**:

# Commit 5 — `TimingModel` + `timing_loader.py` + timing-aware system loading

Cieľ tohto commitu:

* zaviesť **nový timing model**
* vedieť načítať existujúci `timing_config.yaml`
* napojiť timing na `SystemLoader`
* mať prvý typed základ pre:

  * generated clocks
  * false paths
  * timing constraints ako samostatnú vrstvu

Tento commit je stále bezpečný:

* negeneruje ešte nový SDC flow
* neláme legacy `sdc.py`
* len buduje nový loading/model základ

---

# Názov commitu

```text
loader: add timing model, timing loader, and timing-aware system loading
```

---

# 1. Súbory, ktoré pridať

```text
socfw/model/timing.py
socfw/config/timing_schema.py
socfw/config/timing_loader.py
tests/unit/test_timing_loader_new.py
tests/integration/test_system_loader_with_timing.py
```

---

# 2. Súbory, ktoré upraviť

```text
socfw/model/system.py
socfw/config/system_loader.py
socfw/cli/main.py
```

Len minimálne.

---

# 3. `socfw/model/timing.py`

Držal by som to v Commite 5 stále relatívne malé, ale už dosť bohaté na ďalší rast.

```python
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class GeneratedClock:
    name: str
    source: str
    target: str
    divide_by: int | None = None
    multiply_by: int | None = None
    frequency_hz: int | None = None


@dataclass(frozen=True)
class FalsePath:
    from_path: str
    to_path: str


@dataclass
class TimingModel:
    generated_clocks: list[GeneratedClock] = field(default_factory=list)
    false_paths: list[FalsePath] = field(default_factory=list)
    raw: dict = field(default_factory=dict)
```

### prečo takto

Toto ti už pokryje:

* PLL generated clocks
* jednoduché false path výnimky

A zároveň sa to dá neskôr ľahko rozšíriť o:

* multicycle paths
* input/output delays
* clock groups

---

# 4. `socfw/config/timing_schema.py`

Najprv nový cieľový tvar. Loader potom spraví aj legacy mapping.

```python
from __future__ import annotations

from pydantic import BaseModel, Field


class GeneratedClockSchema(BaseModel):
    name: str
    source: str
    target: str
    divide_by: int | None = None
    multiply_by: int | None = None
    frequency_hz: int | None = None


class FalsePathSchema(BaseModel):
    from_path: str
    to_path: str


class TimingDocumentSchema(BaseModel):
    version: int = 2
    kind: str = "timing"
    generated_clocks: list[GeneratedClockSchema] = Field(default_factory=list)
    false_paths: list[FalsePathSchema] = Field(default_factory=list)
```

---

# 5. `socfw/config/timing_loader.py`

Toto je hlavný súbor commitu.

Musí vedieť:

* načítať nový shape
* načítať starší `timing_config.yaml`
* zmapovať ho na `TimingModel`

```python
from __future__ import annotations

from socfw.config.common import load_yaml_file
from socfw.config.timing_schema import TimingDocumentSchema
from socfw.core.diagnostics import Diagnostic, Severity
from socfw.core.result import Result
from socfw.model.timing import FalsePath, GeneratedClock, TimingModel


def _legacy_to_timing_doc(data: dict) -> dict:
    """
    Best-effort mapping from older timing_config.yaml style
    to the new TimingDocumentSchema-compatible shape.
    """
    generated = []
    false_paths = []

    # Common legacy shapes:
    # { generated_clocks: [...] }
    # { clocks: { generated: [...] } }
    # { exceptions: { false_paths: [...] } }
    # Keep this mapper permissive.
    if isinstance(data.get("generated_clocks"), list):
        generated = list(data["generated_clocks"])
    elif isinstance(data.get("clocks"), dict) and isinstance(data["clocks"].get("generated"), list):
        generated = list(data["clocks"]["generated"])

    if isinstance(data.get("false_paths"), list):
        false_paths = list(data["false_paths"])
    elif isinstance(data.get("exceptions"), dict) and isinstance(data["exceptions"].get("false_paths"), list):
        false_paths = list(data["exceptions"]["false_paths"])

    mapped_gen = []
    for g in generated:
        if not isinstance(g, dict):
            continue
        mapped_gen.append({
            "name": g.get("name") or g.get("id") or "gen_clk",
            "source": g.get("source") or g.get("src") or "",
            "target": g.get("target") or g.get("dst") or "",
            "divide_by": g.get("divide_by"),
            "multiply_by": g.get("multiply_by"),
            "frequency_hz": g.get("frequency_hz"),
        })

    mapped_fp = []
    for fp in false_paths:
        if not isinstance(fp, dict):
            continue
        mapped_fp.append({
            "from_path": fp.get("from_path") or fp.get("from") or "",
            "to_path": fp.get("to_path") or fp.get("to") or "",
        })

    return {
        "version": 2,
        "kind": "timing",
        "generated_clocks": mapped_gen,
        "false_paths": mapped_fp,
    }


class TimingLoader:
    def load(self, path: str) -> Result[TimingModel]:
        raw = load_yaml_file(path)
        if not raw.ok:
            return Result(diagnostics=raw.diagnostics)

        data = raw.value or {}
        parse_errors = []

        try:
            doc = TimingDocumentSchema.model_validate(data)
        except Exception as exc:
            parse_errors.append(exc)
            try:
                compat = _legacy_to_timing_doc(data)
                doc = TimingDocumentSchema.model_validate(compat)
            except Exception as exc2:
                return Result(diagnostics=[
                    Diagnostic(
                        code="TIM100",
                        severity=Severity.ERROR,
                        message=f"Invalid timing YAML: {exc2}",
                        subject="timing",
                        file=path,
                    )
                ])

        timing = TimingModel(
            generated_clocks=[
                GeneratedClock(
                    name=g.name,
                    source=g.source,
                    target=g.target,
                    divide_by=g.divide_by,
                    multiply_by=g.multiply_by,
                    frequency_hz=g.frequency_hz,
                )
                for g in doc.generated_clocks
            ],
            false_paths=[
                FalsePath(
                    from_path=fp.from_path,
                    to_path=fp.to_path,
                )
                for fp in doc.false_paths
            ],
            raw=doc.model_dump(),
        )

        diags = []
        if parse_errors:
            diags.append(
                Diagnostic(
                    code="TIM001",
                    severity=Severity.INFO,
                    message="Timing YAML was loaded through legacy compatibility mapping",
                    subject="timing",
                    file=path,
                )
            )

        return Result(value=timing, diagnostics=diags)
```

---

# 6. úprava `socfw/model/system.py`

Doterajší placeholder `timing: object | None` zmeň na reálny typ.

## nahradiť týmto

```python
from __future__ import annotations

from dataclasses import dataclass, field

from socfw.model.board import BoardModel
from socfw.model.project import ProjectModel
from socfw.model.source_context import SourceContext
from socfw.model.timing import TimingModel


@dataclass
class SystemModel:
    board: BoardModel
    project: ProjectModel
    timing: TimingModel | None = None
    ip_catalog: dict = field(default_factory=dict)
    sources: SourceContext = field(default_factory=SourceContext)
```

---

# 7. úprava `socfw/config/system_loader.py`

Teraz treba timing loader napojiť do load chainu.

## nahradiť obsah touto verziou

```python
from __future__ import annotations

from pathlib import Path

from socfw.catalog.board_resolver import BoardResolver
from socfw.catalog.indexer import CatalogIndexer
from socfw.config.board_loader import BoardLoader
from socfw.config.ip_loader import IpLoader
from socfw.config.project_loader import ProjectLoader
from socfw.config.timing_loader import TimingLoader
from socfw.core.diagnostics import Diagnostic, Severity
from socfw.core.result import Result
from socfw.model.source_context import SourceContext
from socfw.model.system import SystemModel


class SystemLoader:
    def __init__(self) -> None:
        self.project_loader = ProjectLoader()
        self.board_loader = BoardLoader()
        self.ip_loader = IpLoader()
        self.timing_loader = TimingLoader()
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

        ip_search_dirs = list(project.registries_ip) + list(pack_index.ip_dirs)
        ip_catalog_res = self.ip_loader.load_catalog(ip_search_dirs)
        diags.extend(ip_catalog_res.diagnostics)
        if not ip_catalog_res.ok or ip_catalog_res.value is None:
            return Result(diagnostics=diags)

        # Timing policy in Phase 1:
        # If timing_config.yaml exists next to project file, load it.
        project_path = Path(project_file).resolve()
        timing_path = project_path.parent / "timing_config.yaml"

        timing = None
        if timing_path.exists():
            t = self.timing_loader.load(str(timing_path))
            diags.extend(t.diagnostics)
            if not t.ok:
                return Result(diagnostics=diags)
            timing = t.value

        system = SystemModel(
            board=brd.value,
            project=project,
            timing=timing,
            ip_catalog=ip_catalog_res.value,
            sources=SourceContext(
                project_file=str(project_path),
                board_file=resolved_board_file,
                timing_file=str(timing_path) if timing_path.exists() else None,
                ip_files={name: "" for name in ip_catalog_res.value.keys()},
            ),
        )

        return Result(value=system, diagnostics=diags)
```

### prečo takto

V Commite 5 ešte nechceme zavádzať plný `project.timing_file` contract.
Najbezpečnejší Phase 1 krok je:

* ak pri projekte existuje `timing_config.yaml`, načítaj ho.

To sedí na tvoj existujúci repo štýl.

---

# 8. úprava `socfw/cli/main.py`

Teraz je užitočné ukázať timing summary pri validate.

## v `cmd_validate` uprav na:

```python
def cmd_validate(args) -> int:
    loaded = SystemLoader().load(args.project)
    _print_diags(loaded.diagnostics)

    if loaded.ok and loaded.value is not None:
        timing_info = "timing=none"
        if loaded.value.timing is not None:
            timing_info = (
                f"timing=generated_clocks:{len(loaded.value.timing.generated_clocks)} "
                f"false_paths:{len(loaded.value.timing.false_paths)}"
            )

        print(
            f"OK: project={loaded.value.project.name} "
            f"board={loaded.value.board.board_id} "
            f"ip_catalog={len(loaded.value.ip_catalog)} "
            f"{timing_info}"
        )
        return 0
    return 1
```

To je malá, ale užitočná UX vec.

---

# 9. `tests/unit/test_timing_loader_new.py`

Tento test overí:

* nový timing schema tvar
* legacy mapping

```python
from pathlib import Path

from socfw.config.timing_loader import TimingLoader


def test_timing_loader_loads_generated_clocks_and_false_paths(tmp_path):
    timing_file = tmp_path / "timing_config.yaml"
    timing_file.write_text(
        """
version: 2
kind: timing

generated_clocks:
  - name: pll_clk
    source: pll0|inclk0
    target: pll0|c0
    divide_by: 1
    multiply_by: 2

false_paths:
  - from_path: "*reset*"
    to_path: "*"
""",
        encoding="utf-8",
    )

    res = TimingLoader().load(str(timing_file))
    assert res.ok
    assert res.value is not None
    assert len(res.value.generated_clocks) == 1
    assert len(res.value.false_paths) == 1


def test_timing_loader_legacy_mapping(tmp_path):
    timing_file = tmp_path / "timing_config.yaml"
    timing_file.write_text(
        """
clocks:
  generated:
    - name: pll_clk
      source: pll0|inclk0
      target: pll0|c0
      divide_by: 1

exceptions:
  false_paths:
    - from: "*reset*"
      to: "*"
""",
        encoding="utf-8",
    )

    res = TimingLoader().load(str(timing_file))
    assert res.ok
    assert res.value is not None
    assert len(res.value.generated_clocks) == 1
    assert len(res.value.false_paths) == 1
```

---

# 10. `tests/integration/test_system_loader_with_timing.py`

Toto je prvý reálny integration test na timing-aware system loading.

```python
from pathlib import Path

from socfw.config.system_loader import SystemLoader


def test_system_loader_loads_adjacent_timing_config(tmp_path):
    packs_builtin = Path("packs/builtin").resolve()

    ip_dir = tmp_path / "ip"
    ip_dir.mkdir()

    rtl_dir = ip_dir / "rtl"
    rtl_dir.mkdir()
    (rtl_dir / "blink_test.sv").write_text("// blink test rtl\n", encoding="utf-8")

    (ip_dir / "blink_test.ip.yaml").write_text(
        """
version: 2
kind: ip

ip:
  name: blink_test
  module: blink_test
  category: standalone

origin:
  kind: source
  packaging: plain_rtl

integration:
  needs_bus: false
  generate_registers: false
  instantiate_directly: true
  dependency_only: false

reset:
  port: null
  active_high: null

clocking:
  primary_input_port: SYS_CLK
  additional_input_ports: []
  outputs: []

artifacts:
  synthesis:
    - rtl/blink_test.sv
  simulation: []
  metadata: []
""",
        encoding="utf-8",
    )

    project_file = tmp_path / "project.yaml"
    project_file.write_text(
        f"""
version: 2
kind: project

project:
  name: demo
  mode: standalone
  board: qmtech_ep4ce55

registries:
  packs:
    - {packs_builtin}
  ip:
    - {ip_dir}

clocks:
  primary:
    domain: sys_clk
    source: board:sys_clk
  generated: []

modules:
  - instance: blink_test
    type: blink_test
""",
        encoding="utf-8",
    )

    (tmp_path / "timing_config.yaml").write_text(
        """
version: 2
kind: timing

generated_clocks:
  - name: pll_clk
    source: pll0|inclk0
    target: pll0|c0
    divide_by: 1
    multiply_by: 2
""",
        encoding="utf-8",
    )

    loaded = SystemLoader().load(str(project_file))
    assert loaded.ok
    assert loaded.value is not None
    assert loaded.value.timing is not None
    assert len(loaded.value.timing.generated_clocks) == 1
```

---

# 11. Čo v tomto commite ešte **nerobiť**

Stále by som nechal bokom:

* nový `build` command
* IR vrstvy
* nový timing emitter
* CPU loader
* bus planning

Commit 5 má riešiť len:

* typed timing loading
* timing-aware `SystemLoader`

To je správny scope.

---

# 12. Čo po Commite 5 overiť

Spusti:

```bash
pip install -e .
socfw validate project_config.yaml
pytest tests/unit/test_timing_loader_new.py
pytest tests/integration/test_system_loader_with_timing.py
```

### očakávanie

* `validate` funguje
* timing config sa vie načítať
* generated clocks sú v novom `TimingModel`

---

# 13. Pravdepodobné riziko v tvojom reálnom repo

Najpravdepodobnejší problém bude, že tvoje existujúce `timing_config.yaml` má iný shape než ten, ktorý som odhadol.

To je v poriadku.

### riešenie

Uprav iba `_legacy_to_timing_doc()`.

Presne tam má byť compatibility vrstva.
Nie v:

* `TimingModel`
* `SystemLoader`
* CLI

---

# 14. Čo má byť Commit 6

Hneď po tomto by som spravil:

## Commit 6

```text
build: add minimal build context and legacy-backed validate/build pipeline
```

Ten prinesie:

* `BuildRequest`
* `BuildResult`
* prvý `FullBuildPipeline`
* prvý `socfw build`
* dočasne ešte napojený na legacy emit backend

A to bude prvý okamih, keď nový CLI nebude len validovať, ale aj generovať.

---

# 15. Môj praktický odporúčaný rytmus

Po Commite 5 by som robil toto:

1. overiť validate na reálnom legacy projekte
2. ak timing neprejde, upraviť iba `_legacy_to_timing_doc()`
3. až keď `validate` stabilne funguje, prejsť na build wrapper
4. ešte stále neprepisovať `rtl_builder.py`

To je správny convergence rytmus.

Ak chceš, ďalšia správa môže byť presne:
👉 **Commit 6 ako file-by-file scaffold: `BuildRequest` + `BuildResult` + prvý `socfw build` nad legacy backend wrapperom**
