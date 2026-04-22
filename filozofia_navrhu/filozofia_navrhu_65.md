Áno. Tu je **Commit 4 ako file-by-file scaffold**:

# Commit 4 — `IpDescriptor` + `ip_loader.py` + pack-aware IP catalog loading

Cieľ tohto commitu:

* zaviesť **nový IP model**
* vedieť načítať existujúce `*.ip.yaml`
* normalizovať artifact cesty relatívne k descriptor súboru
* napojiť IP catalog do `SystemLoader`
* dostať prvý použiteľný `system.ip_catalog`

Stále ešte:

* nelámeš legacy build flow
* ešte negeneruješ nový RTL
* len buduješ nový loading front-end

---

# Názov commitu

```text
loader: add ip model, ip loader, and pack-aware ip catalog loading
```

---

# 1. Súbory, ktoré pridať

```text
socfw/model/ip.py
socfw/config/ip_schema.py
socfw/config/ip_loader.py
tests/unit/test_ip_loader_new.py
tests/integration/test_system_loader_with_ip_catalog.py
```

---

# 2. Súbory, ktoré upraviť

```text
socfw/config/system_loader.py
socfw/catalog/index.py
socfw/catalog/indexer.py
```

Len minimálne.

---

# 3. `socfw/model/ip.py`

Phase 1 minimum.
Zámerne nezaťažovať hneď busmi, register blokmi a vendor metadata modelom. To príde neskôr.

```python
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class IpClockOutput:
    name: str
    frequency_hz: int | None = None
    domain_hint: str | None = None


@dataclass
class IpDescriptor:
    name: str
    module: str
    category: str
    origin_kind: str = "source"
    packaging: str = "plain_rtl"

    needs_bus: bool = False
    generate_registers: bool = False
    instantiate_directly: bool = True
    dependency_only: bool = False

    reset_port: str | None = None
    reset_active_high: bool | None = None

    primary_clock_port: str | None = None
    additional_clock_ports: tuple[str, ...] = ()
    clock_outputs: tuple[IpClockOutput, ...] = ()

    synthesis_files: tuple[str, ...] = ()
    simulation_files: tuple[str, ...] = ()
    metadata_files: tuple[str, ...] = ()

    raw: dict = field(default_factory=dict)
```

---

# 4. `socfw/config/ip_schema.py`

Tu odporúčam spraviť nový cieľový schema tvar, ale s tým, že loader zvládne aj jednoduchší legacy shape.

```python
from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field


class IpMetaSchema(BaseModel):
    name: str
    module: str
    category: str = "generic"


class IpOriginSchema(BaseModel):
    kind: str = "source"
    packaging: str = "plain_rtl"


class IpIntegrationSchema(BaseModel):
    needs_bus: bool = False
    generate_registers: bool = False
    instantiate_directly: bool = True
    dependency_only: bool = False


class IpResetSchema(BaseModel):
    port: str | None = None
    active_high: bool | None = None


class IpClockOutputSchema(BaseModel):
    name: str
    frequency_hz: int | None = None
    domain_hint: str | None = None


class IpClockingSchema(BaseModel):
    primary_input_port: str | None = None
    additional_input_ports: list[str] = Field(default_factory=list)
    outputs: list[IpClockOutputSchema] = Field(default_factory=list)


class IpArtifactsSchema(BaseModel):
    synthesis: list[str] = Field(default_factory=list)
    simulation: list[str] = Field(default_factory=list)
    metadata: list[str] = Field(default_factory=list)


class IpConfigSchema(BaseModel):
    version: int = 2
    kind: Literal["ip"] = "ip"
    ip: IpMetaSchema
    origin: IpOriginSchema = Field(default_factory=IpOriginSchema)
    integration: IpIntegrationSchema = Field(default_factory=IpIntegrationSchema)
    reset: IpResetSchema = Field(default_factory=IpResetSchema)
    clocking: IpClockingSchema = Field(default_factory=IpClockingSchema)
    artifacts: IpArtifactsSchema = Field(default_factory=IpArtifactsSchema)
```

---

# 5. `socfw/config/ip_loader.py`

Toto je hlavný súbor commitu.

Musí:

* načítať descriptor
* vedieť prejsť aj cez legacy shape
* normalizovať paths
* vedieť načítať catalog z viacerých priečinkov

```python
from __future__ import annotations

from pathlib import Path

from socfw.config.common import load_yaml_file
from socfw.config.ip_schema import IpConfigSchema
from socfw.core.diagnostics import Diagnostic, Severity
from socfw.core.result import Result
from socfw.model.ip import IpClockOutput, IpDescriptor


def _legacy_to_ip_doc(data: dict) -> dict:
    """
    Best-effort mapping from older *.ip.yaml shapes to the new schema.
    """
    ip_section = data.get("ip", {})
    files = data.get("files", [])
    interfaces = data.get("interfaces", {})
    clocks = data.get("clocking", {})
    reset = data.get("reset", {})

    name = ip_section.get("name") or data.get("name") or "unknown_ip"
    module = ip_section.get("module") or data.get("module") or name
    category = ip_section.get("category") or data.get("type") or "generic"

    needs_bus = bool(interfaces.get("bus")) if isinstance(interfaces, dict) else False

    primary_clock = None
    if isinstance(clocks, dict):
        primary_clock = clocks.get("primary_input_port") or clocks.get("clock_port") or clocks.get("clock")

    reset_port = None
    reset_active_high = None
    if isinstance(reset, dict):
        reset_port = reset.get("port")
        reset_active_high = reset.get("active_high")

    return {
        "version": 2,
        "kind": "ip",
        "ip": {
            "name": name,
            "module": module,
            "category": category,
        },
        "origin": {
            "kind": data.get("origin", {}).get("kind", "source") if isinstance(data.get("origin"), dict) else "source",
            "packaging": data.get("origin", {}).get("packaging", "plain_rtl") if isinstance(data.get("origin"), dict) else "plain_rtl",
        },
        "integration": {
            "needs_bus": needs_bus,
            "generate_registers": bool(data.get("generate_registers", False)),
            "instantiate_directly": bool(data.get("instantiate_directly", True)),
            "dependency_only": bool(data.get("dependency_only", False)),
        },
        "reset": {
            "port": reset_port,
            "active_high": reset_active_high,
        },
        "clocking": {
            "primary_input_port": primary_clock,
            "additional_input_ports": [],
            "outputs": [],
        },
        "artifacts": {
            "synthesis": list(files) if isinstance(files, list) else [],
            "simulation": [],
            "metadata": [],
        },
    }


class IpLoader:
    def load_file(self, path: str) -> Result[IpDescriptor]:
        raw = load_yaml_file(path)
        if not raw.ok:
            return Result(diagnostics=raw.diagnostics)

        data = raw.value or {}
        base_dir = Path(path).parent

        parse_errors = []

        try:
            doc = IpConfigSchema.model_validate(data)
        except Exception as exc:
            parse_errors.append(exc)
            try:
                compat = _legacy_to_ip_doc(data)
                doc = IpConfigSchema.model_validate(compat)
            except Exception as exc2:
                return Result(diagnostics=[
                    Diagnostic(
                        code="IP100",
                        severity=Severity.ERROR,
                        message=f"Invalid IP YAML: {exc2}",
                        subject="ip",
                        file=path,
                    )
                ])

        ipd = IpDescriptor(
            name=doc.ip.name,
            module=doc.ip.module,
            category=doc.ip.category,
            origin_kind=doc.origin.kind,
            packaging=doc.origin.packaging,
            needs_bus=doc.integration.needs_bus,
            generate_registers=doc.integration.generate_registers,
            instantiate_directly=doc.integration.instantiate_directly,
            dependency_only=doc.integration.dependency_only,
            reset_port=doc.reset.port,
            reset_active_high=doc.reset.active_high,
            primary_clock_port=doc.clocking.primary_input_port,
            additional_clock_ports=tuple(doc.clocking.additional_input_ports),
            clock_outputs=tuple(
                IpClockOutput(
                    name=o.name,
                    frequency_hz=o.frequency_hz,
                    domain_hint=o.domain_hint,
                )
                for o in doc.clocking.outputs
            ),
            synthesis_files=tuple(str((base_dir / p).resolve()) for p in doc.artifacts.synthesis),
            simulation_files=tuple(str((base_dir / p).resolve()) for p in doc.artifacts.simulation),
            metadata_files=tuple(str((base_dir / p).resolve()) for p in doc.artifacts.metadata),
            raw=doc.model_dump(),
        )

        diags = []
        if parse_errors:
            diags.append(
                Diagnostic(
                    code="IP001",
                    severity=Severity.INFO,
                    message="IP YAML was loaded through legacy compatibility mapping",
                    subject="ip",
                    file=path,
                )
            )

        return Result(value=ipd, diagnostics=diags)

    def load_catalog(self, search_dirs: list[str]) -> Result[dict[str, IpDescriptor]]:
        catalog: dict[str, IpDescriptor] = {}
        diags: list[Diagnostic] = []

        for root in search_dirs:
            root_path = Path(root).expanduser().resolve()
            if not root_path.exists():
                continue

            # Support both flat and nested pack-style trees.
            for fp in sorted(root_path.rglob("*.ip.yaml")):
                res = self.load_file(str(fp))
                diags.extend(res.diagnostics)

                if not res.ok or res.value is None:
                    continue

                if res.value.name in catalog:
                    diags.append(
                        Diagnostic(
                            code="IP101",
                            severity=Severity.WARNING,
                            message=f"Duplicate IP descriptor '{res.value.name}' found; keeping first match",
                            subject="ip.catalog",
                            file=str(fp),
                        )
                    )
                    continue

                catalog[res.value.name] = res.value

        return Result(value=catalog, diagnostics=diags)
```

---

# 6. úprava `socfw/catalog/index.py`

V Commite 3 sme tam už mali `ip_dirs`, ale ak nie, finalizuj to takto:

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

# 7. úprava `socfw/catalog/indexer.py`

Ak už máš `ip_dirs`, stačí overiť, že indexer ich vypĺňa.

Výsledok má byť:

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

            # vendor packs often place reusable IP beneath vendor/...
            vendor_root = rp / "vendor"
            if vendor_root.exists():
                idx.ip_dirs.append(str(vendor_root))

        return idx
```

Dôležité:

* týmto už neskôr vendor packy budú vedieť fungovať bez ďalšej zmeny indexera

---

# 8. úprava `socfw/config/system_loader.py`

Teraz treba napojiť `IpLoader`.

## nahradiť obsah touto verziou

```python
from __future__ import annotations

from pathlib import Path

from socfw.catalog.board_resolver import BoardResolver
from socfw.catalog.indexer import CatalogIndexer
from socfw.config.board_loader import BoardLoader
from socfw.config.ip_loader import IpLoader
from socfw.config.project_loader import ProjectLoader
from socfw.core.diagnostics import Diagnostic, Severity
from socfw.core.result import Result
from socfw.model.source_context import SourceContext
from socfw.model.system import SystemModel


class SystemLoader:
    def __init__(self) -> None:
        self.project_loader = ProjectLoader()
        self.board_loader = BoardLoader()
        self.ip_loader = IpLoader()
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

        system = SystemModel(
            board=brd.value,
            project=project,
            timing=None,
            ip_catalog=ip_catalog_res.value,
            sources=SourceContext(
                project_file=str(Path(project_file).resolve()),
                board_file=resolved_board_file,
                ip_files={name: "" for name in ip_catalog_res.value.keys()},
            ),
        )

        return Result(value=system, diagnostics=diags)
```

### poznámka

`ip_files={name: "" ...}` je zatiaľ len placeholder pre Phase 1.
Presná mapovacia stopa `name -> path` sa dá doplniť v ďalšom commite, ak budeš chcieť lepšie diagnostics.

---

# 9. `tests/unit/test_ip_loader_new.py`

Tento test má overiť:

* nový schema tvar
* normalizáciu paths

```python
from pathlib import Path

from socfw.config.ip_loader import IpLoader


def test_ip_loader_normalizes_artifact_paths(tmp_path):
    ip_dir = tmp_path / "ip"
    ip_dir.mkdir()

    rtl_dir = ip_dir / "rtl"
    rtl_dir.mkdir()
    (rtl_dir / "demo.sv").write_text("// demo\n", encoding="utf-8")

    ip_file = ip_dir / "demo.ip.yaml"
    ip_file.write_text(
        """
version: 2
kind: ip

ip:
  name: demo
  module: demo
  category: peripheral

origin:
  kind: source
  packaging: plain_rtl

integration:
  needs_bus: false
  generate_registers: false
  instantiate_directly: true
  dependency_only: false

reset:
  port: RESET_N
  active_high: false

clocking:
  primary_input_port: SYS_CLK
  additional_input_ports: []
  outputs: []

artifacts:
  synthesis:
    - rtl/demo.sv
  simulation: []
  metadata: []
""",
        encoding="utf-8",
    )

    res = IpLoader().load_file(str(ip_file))
    assert res.ok
    assert res.value is not None
    assert res.value.name == "demo"
    assert len(res.value.synthesis_files) == 1
    assert res.value.synthesis_files[0].endswith("rtl/demo.sv")
```

---

# 10. `tests/integration/test_system_loader_with_ip_catalog.py`

Toto je prvý reálny integration test na:

* project loader
* board resolver
* board loader
* ip catalog loading

```python
from pathlib import Path

from socfw.config.system_loader import SystemLoader


def test_system_loader_loads_project_board_and_ip_catalog(tmp_path):
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

    loaded = SystemLoader().load(str(project_file))
    assert loaded.ok
    assert loaded.value is not None
    assert loaded.value.board.board_id == "qmtech_ep4ce55"
    assert "blink_test" in loaded.value.ip_catalog
```

---

# 11. Čo v tomto commite ešte **nerobiť**

Stále by som vedome nechal bokom:

* timing loader
* CPU model/loader
* build pipeline
* `socfw build`
* nový emit flow
* pack-aware vendor metadata

Commit 4 má riešiť len:

* IP descriptors
* IP catalog loading
* artifact path normalization

To je zdravý scope.

---

# 12. Čo po Commite 4 overiť

Spusti:

```bash
pip install -e .
socfw validate project_config.yaml
pytest tests/unit/test_ip_loader_new.py
pytest tests/integration/test_system_loader_with_ip_catalog.py
```

### očakávanie

* `socfw validate` už vie:

  * načítať projekt
  * načítať board
  * načítať aspoň základný IP catalog

Aj keď ešte nič negeneruje, máš prvý slušný converged loading chain.

---

# 13. Pravdepodobné riziko v tvojom reálnom repo

Najpravdepodobnejšie sa zasekneš na tom, že tvoje aktuálne `*.ip.yaml` súbory nebudú mať presne tvar, ktorý sme predpokladali.

To je v poriadku.

### riešenie

Rozšír len `_legacy_to_ip_doc()`.

To je správne miesto pre Phase 1 kompatibilitu.

Nepchaj compatibility logiku do:

* `SystemLoader`
* `IpDescriptor`
* testov

len do:

* `ip_loader.py`

---

# 14. Čo má byť Commit 5

Hneď po tomto by som spravil:

## Commit 5

```text
loader: add timing model, timing loader, and first timing-aware validation
```

Ten prinesie:

* `TimingModel`
* `timing_loader.py`
* načítanie `timing_config.yaml`
* prvé typed timing vstupy
* základ pre PLL/generated clock convergence

A to je presne ďalší logický krok pred prvým reálnym build wrapperom.

---

# 15. Môj praktický odporúčaný rytmus

Po Commite 4 by som robil toto:

1. skúsiť `socfw validate` na reálny legacy project
2. ak padá na IP YAML shape, opraviť iba `_legacy_to_ip_doc()`
3. až keď validate funguje, prejsť na timing
4. ešte stále nesiahať na nový RTL build

To je správny convergence rytmus.

Ak chceš, ďalšia správa môže byť presne:
👉 **Commit 5 ako file-by-file scaffold: `TimingModel` + `timing_loader.py` + timing-aware system loading**
