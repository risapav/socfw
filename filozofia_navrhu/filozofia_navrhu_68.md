Áno. Tu je **Commit 7 ako file-by-file scaffold**:

# Commit 7 — `CpuDescriptor` + `cpu_loader.py` + `*.cpu.yaml` catalog loading

Cieľ tohto commitu:

* zaviesť **nový CPU descriptor model**
* vedieť načítať `*.cpu.yaml`
* napojiť CPU catalog do `SystemLoader`
* pripraviť základ pre:

  * `dummy_cpu`
  * `picorv32_min`
  * neskôr IRQ ABI, firmware flow a bus master contract

Toto je veľmi dôležitý commit, lebo od tohto bodu už nový flow nebude len:

* board + project + IP

ale začne rozumieť aj:

* **CPU ako first-class objektu**

---

# Názov commitu

```text
loader: add cpu descriptor model and cpu catalog loading
```

---

# 1. Súbory, ktoré pridať

```text
socfw/model/cpu.py
socfw/config/cpu_schema.py
socfw/config/cpu_loader.py
tests/unit/test_cpu_loader_new.py
tests/integration/test_system_loader_with_cpu_catalog.py
```

---

# 2. Súbory, ktoré upraviť

```text
socfw/model/project.py
socfw/model/system.py
socfw/config/project_schema.py
socfw/config/project_loader.py
socfw/config/system_loader.py
socfw/catalog/index.py
socfw/catalog/indexer.py
socfw/cli/main.py
```

Len kontrolované zmeny.

---

# 3. `socfw/model/cpu.py`

Na Commit 7 držal by som CPU model ešte relatívne jednoduchý, ale už dosť bohatý na ďalší rast.

```python
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class CpuBusMasterDesc:
    port_name: str
    protocol: str
    addr_width: int = 32
    data_width: int = 32


@dataclass
class CpuDescriptor:
    name: str
    module: str
    family: str

    clock_port: str = "SYS_CLK"
    reset_port: str = "RESET_N"
    irq_port: str | None = None

    bus_master: CpuBusMasterDesc | None = None
    default_params: dict = field(default_factory=dict)
    artifacts: tuple[str, ...] = ()
    raw: dict = field(default_factory=dict)
```

---

# 4. úprava `socfw/model/project.py`

Doteraz tam CPU nebol. Teraz ho doplníme.

## nahradiť týmto

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
class ProjectCpu:
    instance: str
    type_name: str
    fabric: str | None = None
    reset_vector: int | None = None
    params: dict = field(default_factory=dict)
    raw: dict = field(default_factory=dict)


@dataclass
class ProjectModel:
    name: str
    mode: str
    board_ref: str
    board_file: str | None = None
    registries_packs: list[str] = field(default_factory=list)
    registries_ip: list[str] = field(default_factory=list)
    registries_cpu: list[str] = field(default_factory=list)
    modules: list[ProjectModule] = field(default_factory=list)
    cpu: ProjectCpu | None = None
    raw: dict = field(default_factory=dict)
```

---

# 5. úprava `socfw/model/system.py`

Doplň CPU catalog aj resolved CPU descriptor.

## nahradiť týmto

```python
from __future__ import annotations

from dataclasses import dataclass, field

from socfw.model.board import BoardModel
from socfw.model.project import ProjectModel
from socfw.model.source_context import SourceContext
from socfw.model.timing import TimingModel
from socfw.model.cpu import CpuDescriptor


@dataclass
class SystemModel:
    board: BoardModel
    project: ProjectModel
    timing: TimingModel | None = None
    ip_catalog: dict = field(default_factory=dict)
    cpu_catalog: dict[str, CpuDescriptor] = field(default_factory=dict)
    sources: SourceContext = field(default_factory=SourceContext)

    def cpu_desc(self) -> CpuDescriptor | None:
        if self.project.cpu is None:
            return None
        return self.cpu_catalog.get(self.project.cpu.type_name)
```

---

# 6. `socfw/config/cpu_schema.py`

Toto je nový typed schema kontrakt.

```python
from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field


class CpuMetaSchema(BaseModel):
    name: str
    module: str
    family: str


class CpuBusMasterSchema(BaseModel):
    port_name: str
    protocol: str
    addr_width: int = 32
    data_width: int = 32


class CpuDescriptorSchema(BaseModel):
    version: int = 2
    kind: Literal["cpu"] = "cpu"
    cpu: CpuMetaSchema
    clock_port: str = "SYS_CLK"
    reset_port: str = "RESET_N"
    irq_port: str | None = None
    bus_master: CpuBusMasterSchema | None = None
    default_params: dict = Field(default_factory=dict)
    artifacts: list[str] = Field(default_factory=list)
```

---

# 7. `socfw/config/cpu_loader.py`

Toto je hlavný súbor commitu.

Musí:

* načítať `*.cpu.yaml`
* vedieť načítať catalog
* normalizovať artifact paths

```python
from __future__ import annotations

from pathlib import Path

from socfw.config.common import load_yaml_file
from socfw.config.cpu_schema import CpuDescriptorSchema
from socfw.core.diagnostics import Diagnostic, Severity
from socfw.core.result import Result
from socfw.model.cpu import CpuBusMasterDesc, CpuDescriptor


def _legacy_to_cpu_doc(data: dict) -> dict:
    """
    Best-effort mapping for older CPU descriptor shapes.
    """
    cpu = data.get("cpu", {})
    name = cpu.get("name") or data.get("name") or "unknown_cpu"
    module = cpu.get("module") or data.get("module") or name
    family = cpu.get("family") or data.get("family") or "generic"

    bus_master = None
    if isinstance(data.get("bus_master"), dict):
        bm = data["bus_master"]
        bus_master = {
            "port_name": bm.get("port_name", "bus"),
            "protocol": bm.get("protocol", "simple_bus"),
            "addr_width": bm.get("addr_width", 32),
            "data_width": bm.get("data_width", 32),
        }

    return {
        "version": 2,
        "kind": "cpu",
        "cpu": {
            "name": name,
            "module": module,
            "family": family,
        },
        "clock_port": data.get("clock_port", "SYS_CLK"),
        "reset_port": data.get("reset_port", "RESET_N"),
        "irq_port": data.get("irq_port"),
        "bus_master": bus_master,
        "default_params": dict(data.get("default_params", {})),
        "artifacts": list(data.get("artifacts", [])),
    }


class CpuLoader:
    def load_file(self, path: str) -> Result[CpuDescriptor]:
        raw = load_yaml_file(path)
        if not raw.ok:
            return Result(diagnostics=raw.diagnostics)

        data = raw.value or {}
        base_dir = Path(path).parent
        parse_errors = []

        try:
            doc = CpuDescriptorSchema.model_validate(data)
        except Exception as exc:
            parse_errors.append(exc)
            try:
                compat = _legacy_to_cpu_doc(data)
                doc = CpuDescriptorSchema.model_validate(compat)
            except Exception as exc2:
                return Result(diagnostics=[
                    Diagnostic(
                        code="CPU100",
                        severity=Severity.ERROR,
                        message=f"Invalid CPU descriptor YAML: {exc2}",
                        subject="cpu",
                        file=path,
                    )
                ])

        cpu = CpuDescriptor(
            name=doc.cpu.name,
            module=doc.cpu.module,
            family=doc.cpu.family,
            clock_port=doc.clock_port,
            reset_port=doc.reset_port,
            irq_port=doc.irq_port,
            bus_master=(
                CpuBusMasterDesc(
                    port_name=doc.bus_master.port_name,
                    protocol=doc.bus_master.protocol,
                    addr_width=doc.bus_master.addr_width,
                    data_width=doc.bus_master.data_width,
                )
                if doc.bus_master is not None else None
            ),
            default_params=dict(doc.default_params),
            artifacts=tuple(str((base_dir / p).resolve()) for p in doc.artifacts),
            raw=doc.model_dump(),
        )

        diags = []
        if parse_errors:
            diags.append(
                Diagnostic(
                    code="CPU001",
                    severity=Severity.INFO,
                    message="CPU descriptor was loaded through legacy compatibility mapping",
                    subject="cpu",
                    file=path,
                )
            )

        return Result(value=cpu, diagnostics=diags)

    def load_catalog(self, search_dirs: list[str]) -> Result[dict[str, CpuDescriptor]]:
        catalog: dict[str, CpuDescriptor] = {}
        diags: list[Diagnostic] = []

        for root in search_dirs:
            root_path = Path(root).expanduser().resolve()
            if not root_path.exists():
                continue

            for fp in sorted(root_path.rglob("*.cpu.yaml")):
                res = self.load_file(str(fp))
                diags.extend(res.diagnostics)

                if not res.ok or res.value is None:
                    continue

                if res.value.name in catalog:
                    diags.append(
                        Diagnostic(
                            code="CPU101",
                            severity=Severity.WARNING,
                            message=f"Duplicate CPU descriptor '{res.value.name}' found; keeping first match",
                            subject="cpu.catalog",
                            file=str(fp),
                        )
                    )
                    continue

                catalog[res.value.name] = res.value

        return Result(value=catalog, diagnostics=diags)
```

---

# 8. úprava `socfw/config/project_schema.py`

Teraz musí schema vedieť aj `cpu:` sekciu a `registries.cpu`.

## nahradiť týmto

```python
from __future__ import annotations

from pydantic import BaseModel, Field


class ProjectModuleSchema(BaseModel):
    instance: str
    type: str
    params: dict = Field(default_factory=dict)
    clocks: dict = Field(default_factory=dict)
    bind: dict = Field(default_factory=dict)


class ProjectCpuSchema(BaseModel):
    instance: str
    type: str
    fabric: str | None = None
    reset_vector: int | None = None
    params: dict = Field(default_factory=dict)


class RegistriesSchema(BaseModel):
    packs: list[str] = Field(default_factory=list)
    ip: list[str] = Field(default_factory=list)
    cpu: list[str] = Field(default_factory=list)


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
    cpu: ProjectCpuSchema | None = None
    modules: list[ProjectModuleSchema] = Field(default_factory=list)
```

---

# 9. úprava `socfw/config/project_loader.py`

Treba doplniť:

* `registries.cpu`
* `cpu:` sekciu
* legacy mapping pre CPU, ak sa v legacy projekte objaví

## uprav `_legacy_to_project_doc()` a skladanie modelu

### nahradiť týmto

```python
from __future__ import annotations

from pathlib import Path

from socfw.config.common import load_yaml_file
from socfw.config.project_schema import ProjectConfigSchema
from socfw.core.diagnostics import Diagnostic, Severity
from socfw.core.result import Result
from socfw.model.project import ProjectCpu, ProjectModel, ProjectModule


def _legacy_to_project_doc(data: dict) -> dict:
    design = data.get("design", {})
    board = data.get("board", {})
    plugins = data.get("plugins", {})
    modules = data.get("modules", [])
    cpu = data.get("cpu", {})

    mapped_modules = []
    for m in modules:
        mapped_modules.append({
            "instance": m.get("name") or m.get("instance") or m.get("type") or "u0",
            "type": m.get("type") or m.get("module") or "unknown",
            "params": m.get("params", {}),
            "clocks": m.get("clocks", {}),
            "bind": m.get("bind", {}),
        })

    mapped_cpu = None
    if isinstance(cpu, dict) and cpu:
        mapped_cpu = {
            "instance": cpu.get("instance", "cpu0"),
            "type": cpu.get("type") or cpu.get("name") or "unknown_cpu",
            "fabric": cpu.get("fabric"),
            "reset_vector": cpu.get("reset_vector"),
            "params": cpu.get("params", {}),
        }

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
            "cpu": list(plugins.get("cpu", [])),
        },
        "clocks": {
            "primary": data.get("clocks", {}).get("primary") if isinstance(data.get("clocks"), dict) else None,
            "generated": data.get("clocks", {}).get("generated", []) if isinstance(data.get("clocks"), dict) else [],
        },
        "cpu": mapped_cpu,
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
            registries_cpu=list(doc.registries.cpu),
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
            cpu=(
                ProjectCpu(
                    instance=doc.cpu.instance,
                    type_name=doc.cpu.type,
                    fabric=doc.cpu.fabric,
                    reset_vector=doc.cpu.reset_vector,
                    params=dict(doc.cpu.params),
                    raw=doc.cpu.model_dump(),
                )
                if doc.cpu is not None else None
            ),
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

# 10. úprava `socfw/catalog/index.py`

Ak ešte nemáš `cpu_dirs`, ponechaj toto:

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

# 11. úprava `socfw/catalog/indexer.py`

Treba zabezpečiť, že packy vedia poskytnúť aj `cpu/` subtree.

## nahradiť týmto

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

            vendor_root = rp / "vendor"
            if vendor_root.exists():
                idx.ip_dirs.append(str(vendor_root))

        return idx
```

---

# 12. úprava `socfw/config/system_loader.py`

Teraz napoj CPU catalog loading.

## nahradiť obsah touto verziou

```python
from __future__ import annotations

from pathlib import Path

from socfw.catalog.board_resolver import BoardResolver
from socfw.catalog.indexer import CatalogIndexer
from socfw.config.board_loader import BoardLoader
from socfw.config.cpu_loader import CpuLoader
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
        self.cpu_loader = CpuLoader()
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

        cpu_search_dirs = list(project.registries_cpu) + list(pack_index.cpu_dirs)
        cpu_catalog_res = self.cpu_loader.load_catalog(cpu_search_dirs)
        diags.extend(cpu_catalog_res.diagnostics)
        if not cpu_catalog_res.ok or cpu_catalog_res.value is None:
            return Result(diagnostics=diags)

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
            cpu_catalog=cpu_catalog_res.value,
            sources=SourceContext(
                project_file=str(project_path),
                board_file=resolved_board_file,
                timing_file=str(timing_path) if timing_path.exists() else None,
                ip_files={name: "" for name in ip_catalog_res.value.keys()},
            ),
        )

        return Result(value=system, diagnostics=diags)
```

---

# 13. úprava `socfw/cli/main.py`

Teraz je užitočné ukázať aj CPU summary.

## v `cmd_validate` uprav na

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

        cpu_info = "cpu=none"
        if loaded.value.project.cpu is not None:
            resolved = loaded.value.cpu_desc()
            cpu_info = f"cpu={loaded.value.project.cpu.type_name}"
            if resolved is None:
                cpu_info += "(unresolved)"
            else:
                cpu_info += f"(module={resolved.module})"

        print(
            f"OK: project={loaded.value.project.name} "
            f"board={loaded.value.board.board_id} "
            f"ip_catalog={len(loaded.value.ip_catalog)} "
            f"cpu_catalog={len(loaded.value.cpu_catalog)} "
            f"{cpu_info} "
            f"{timing_info}"
        )
        return 0
    return 1
```

---

# 14. `tests/unit/test_cpu_loader_new.py`

Tento test overí:

* nový CPU descriptor schema
* normalizáciu artifacts
* bus master contract

```python
from pathlib import Path

from socfw.config.cpu_loader import CpuLoader


def test_cpu_loader_loads_descriptor_and_normalizes_artifacts(tmp_path):
    cpu_dir = tmp_path / "cpu"
    cpu_dir.mkdir()

    rtl_dir = cpu_dir / "rtl"
    rtl_dir.mkdir()
    (rtl_dir / "dummy_cpu.sv").write_text("// dummy cpu\n", encoding="utf-8")

    cpu_file = cpu_dir / "dummy_cpu.cpu.yaml"
    cpu_file.write_text(
        """
version: 2
kind: cpu

cpu:
  name: dummy_cpu
  module: dummy_cpu
  family: test

clock_port: SYS_CLK
reset_port: RESET_N
irq_port: irq

bus_master:
  port_name: bus
  protocol: simple_bus
  addr_width: 32
  data_width: 32

default_params: {}

artifacts:
  - rtl/dummy_cpu.sv
""",
        encoding="utf-8",
    )

    res = CpuLoader().load_file(str(cpu_file))
    assert res.ok
    assert res.value is not None
    assert res.value.name == "dummy_cpu"
    assert res.value.module == "dummy_cpu"
    assert res.value.bus_master is not None
    assert res.value.bus_master.protocol == "simple_bus"
    assert len(res.value.artifacts) == 1
    assert res.value.artifacts[0].endswith("rtl/dummy_cpu.sv")
```

---

# 15. `tests/integration/test_system_loader_with_cpu_catalog.py`

Toto je prvý reálny integration test na:

* project loader
* board resolver
* board loader
* ip catalog
* cpu catalog

```python
from pathlib import Path

from socfw.config.system_loader import SystemLoader


def test_system_loader_loads_cpu_catalog_and_resolves_project_cpu(tmp_path):
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

    cpu_dir = tmp_path / "cpu"
    cpu_dir.mkdir()
    cpu_rtl_dir = cpu_dir / "rtl"
    cpu_rtl_dir.mkdir()
    (cpu_rtl_dir / "dummy_cpu.sv").write_text("// dummy cpu rtl\n", encoding="utf-8")

    (cpu_dir / "dummy_cpu.cpu.yaml").write_text(
        """
version: 2
kind: cpu

cpu:
  name: dummy_cpu
  module: dummy_cpu
  family: test

clock_port: SYS_CLK
reset_port: RESET_N
irq_port: irq

bus_master:
  port_name: bus
  protocol: simple_bus
  addr_width: 32
  data_width: 32

default_params: {}

artifacts:
  - rtl/dummy_cpu.sv
""",
        encoding="utf-8",
    )

    project_file = tmp_path / "project.yaml"
    project_file.write_text(
        f"""
version: 2
kind: project

project:
  name: demo_soc
  mode: soc
  board: qmtech_ep4ce55

registries:
  packs:
    - {packs_builtin}
  ip:
    - {ip_dir}
  cpu:
    - {cpu_dir}

clocks:
  primary:
    domain: sys_clk
    source: board:sys_clk
  generated: []

cpu:
  instance: cpu0
  type: dummy_cpu
  fabric: main

modules:
  - instance: blink_test
    type: blink_test
""",
        encoding="utf-8",
    )

    loaded = SystemLoader().load(str(project_file))
    assert loaded.ok
    assert loaded.value is not None
    assert loaded.value.project.cpu is not None
    assert loaded.value.project.cpu.type_name == "dummy_cpu"
    assert "dummy_cpu" in loaded.value.cpu_catalog
    assert loaded.value.cpu_desc() is not None
```

---

# 16. Čo v tomto commite ešte **nerobiť**

Vedome by som nechal bokom:

* CPU validation rules
* IRQ ABI model
* firmware model
* bus planning
* RAM model
* nový RTL emitter

Commit 7 má vyriešiť len:

* CPU descriptors
* CPU catalog loading
* project CPU resolution

To je správny scope.

---

# 17. Čo po Commite 7 overiť

Spusti:

```bash
pip install -e .
socfw validate project_config.yaml
pytest tests/unit/test_cpu_loader_new.py
pytest tests/integration/test_system_loader_with_cpu_catalog.py
```

### očakávanie

* validate už vie načítať CPU descriptors
* project CPU sa vie resolve-núť cez catalog
* nový flow má:

  * board
  * project
  * ip
  * timing
  * cpu

To je veľmi slušný convergence checkpoint.

---

# 18. Pravdepodobné riziko v tvojom reálnom repo

Najpravdepodobnejšie sa zasekneš na tom, že v legacy projekte ešte nemáš CPU sekciu v očakávanom shape.

To je v poriadku.

### riešenie

Rozšír len `_legacy_to_project_doc()` v `project_loader.py`.

Presne tam má byť táto compatibility vrstva.

Nie v:

* `SystemLoader`
* `CpuDescriptor`
* CLI

---

# 19. Čo má byť Commit 8

Po tomto by som išiel na prvé skutočné validation pravidlá pre nový model.

## Commit 8

```text
validate: add first real validation rules for board project cpu and ip resolution
```

Ten by priniesol:

* `UnknownCpuTypeRule`
* `UnknownIpTypeRule`
* `MissingBoardRule` / board resolution errors cleanup
* prvé čitateľné diagnostics

To je ďalší správny krok pred tým, než začneš robiť nový IR/build stack.

---

# 20. Môj praktický odporúčaný rytmus

Po Commite 7 by som spravil presne toto:

1. potvrdiť, že `socfw validate` funguje na reálnom legacy projekte
2. ak CPU project shape nesedí, opraviť len compatibility mapping
3. až potom spraviť validation rules
4. stále ešte neprepisovať nový generátor

To je správny convergence rytmus.

Ak chceš, ďalšia správa môže byť presne:
👉 **Commit 8 ako file-by-file scaffold: prvé validation rules + čitateľné diagnostics pre board/project/ip/cpu resolution**
