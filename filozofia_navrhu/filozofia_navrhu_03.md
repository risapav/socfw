Nižšie je **konkrétny skeleton nového frameworku**: balíky, hlavné typy, rozhrania a tok buildu. Navrhujem ho tak, aby zachoval dobrú myšlienku dnešného `builder -> IR -> render`, ale odstránil legacy mosty, implicitné fallbacky a rozliatu logiku.

## 1. Kostra projektu

```text
socfw/
  pyproject.toml
  src/socfw/
    __init__.py

    api/
      diagnostics.py
      result.py
      types.py
      plugin.py

    config/
      loader.py
      merger.py
      provenance.py
      raw_models.py

    domain/
      enums.py
      model.py
      refs.py

    validate/
      runner.py
      rules/
        addresses.py
        clocks.py
        board.py
        buses.py
        ips.py

    elaborate/
      pipeline.py
      addressing.py
      clocks.py
      resets.py
      buses.py
      board_ports.py
      dependencies.py

    ir/
      rtl.py
      timing.py
      software.py
      board.py
      docs.py

    build/
      request.py
      context.py
      pipeline.py
      manifest.py

    emit/
      base.py
      registry.py
      renderer.py
      rtl_emitter.py
      timing_emitter.py
      software_emitter.py
      board_emitter.py
      docs_emitter.py

    plugins/
      builtin/
        boards/
          qmtech_ep4ce55.py
        buses/
          simple_bus.py
          axi_lite.py
        ips/
          gpio.py
          uart.py
          timer.py

    reports/
      json_report.py
      markdown_report.py

    cli/
      main.py
```

---

## 2. Základné API typy

### `api/diagnostics.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field
from enum import Enum
from typing import Optional


class Severity(str, Enum):
    INFO = "info"
    WARNING = "warning"
    ERROR = "error"


@dataclass(frozen=True)
class SourceLocation:
    file: str
    line: int | None = None
    column: int | None = None
    path: str | None = None   # napr. $.peripherals[1].base


@dataclass(frozen=True)
class Diagnostic:
    code: str
    severity: Severity
    message: str
    subject: str
    locations: tuple[SourceLocation, ...] = ()
    hints: tuple[str, ...] = ()
    related: tuple[str, ...] = ()
```

Toto je základ všetkého. Namiesto `print()` a `sys.exit()` bude core vracať diagnostiky. Dnešný framework ide často priamo na stdout a exit, čo sa pre moderné jadro nehodí.

---

### `api/result.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field
from typing import Generic, TypeVar

from .diagnostics import Diagnostic, Severity

T = TypeVar("T")


@dataclass
class Result(Generic[T]):
    value: T | None = None
    diagnostics: list[Diagnostic] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not any(d.severity == Severity.ERROR for d in self.diagnostics)

    def require(self) -> T:
        if not self.ok or self.value is None:
            raise RuntimeError("Result contains errors")
        return self.value
```

---

## 3. Raw config vrstva

### `config/raw_models.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field
from typing import Any


@dataclass
class RawDocument:
    kind: str
    data: dict[str, Any]
    source_file: str


@dataclass
class RawConfigBundle:
    project: RawDocument | None = None
    board: RawDocument | None = None
    timing: RawDocument | None = None
    ip_registry: list[RawDocument] = field(default_factory=list)
    bus_registry: list[RawDocument] = field(default_factory=list)
    extra: list[RawDocument] = field(default_factory=list)
```

### `config/provenance.py`

```python
from __future__ import annotations
from dataclasses import dataclass


@dataclass(frozen=True)
class Provenance:
    source_file: str
    yaml_path: str
    line: int | None = None
```

### `config/loader.py`

```python
from __future__ import annotations
from pathlib import Path
import yaml

from socfw.api.result import Result
from socfw.api.diagnostics import Diagnostic, Severity, SourceLocation
from socfw.config.raw_models import RawConfigBundle, RawDocument


class ConfigLoader:
    def load(self, project_file: str) -> Result[RawConfigBundle]:
        diags: list[Diagnostic] = []
        bundle = RawConfigBundle()

        path = Path(project_file)
        if not path.exists():
            return Result(
                diagnostics=[
                    Diagnostic(
                        code="CFG001",
                        severity=Severity.ERROR,
                        message=f"Project file not found: {project_file}",
                        subject="project config",
                        locations=(SourceLocation(file=project_file),),
                    )
                ]
            )

        try:
            with path.open("r", encoding="utf-8") as f:
                data = yaml.safe_load(f) or {}
        except Exception as e:
            return Result(
                diagnostics=[
                    Diagnostic(
                        code="CFG002",
                        severity=Severity.ERROR,
                        message=f"Failed to parse YAML: {e}",
                        subject="project config",
                        locations=(SourceLocation(file=project_file),),
                    )
                ]
            )

        bundle.project = RawDocument(
            kind="project",
            data=data,
            source_file=str(path),
        )
        return Result(value=bundle, diagnostics=diags)
```

Túto vrstvu by som držal čisto na loading a source tracking, nie na doménovej interpretácii.

---

## 4. Kanonický doménový model

### `domain/enums.py`

```python
from enum import Enum


class PortDir(str, Enum):
    INPUT = "input"
    OUTPUT = "output"
    INOUT = "inout"


class AccessType(str, Enum):
    RO = "ro"
    RW = "rw"
    WO = "wo"
```

### `domain/model.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field
from typing import Any

from .enums import PortDir, AccessType


@dataclass(frozen=True)
class BoardPort:
    name: str
    direction: PortDir
    width: int
    io_standard: str | None = None


@dataclass(frozen=True)
class ClockDomain:
    name: str
    frequency_hz: int
    source: str
    board_port: str | None = None


@dataclass(frozen=True)
class ResetDomain:
    name: str
    active_low: bool
    source: str
    sync_stages: int = 2
    sync_from: str | None = None


@dataclass(frozen=True)
class AddressRegion:
    base: int
    size: int

    @property
    def end(self) -> int:
        return self.base + self.size - 1


@dataclass(frozen=True)
class RegisterDef:
    name: str
    offset: int
    width: int
    access: AccessType
    reset: int = 0
    desc: str = ""


@dataclass(frozen=True)
class ExternalPortRequirement:
    name: str
    top_name: str
    direction: PortDir
    width: int


@dataclass(frozen=True)
class BusAttachment:
    protocol: str
    role: str          # master/slave
    region: AddressRegion | None = None
    data_width: int = 32
    addr_width: int = 32


@dataclass
class PeripheralInstance:
    inst_name: str
    kind: str
    params: dict[str, Any] = field(default_factory=dict)
    registers: list[RegisterDef] = field(default_factory=list)
    ext_ports: list[ExternalPortRequirement] = field(default_factory=list)
    bus: BusAttachment | None = None
    irq_ids: list[int] = field(default_factory=list)
    clocks: list[str] = field(default_factory=list)
    resets: list[str] = field(default_factory=list)


@dataclass
class Board:
    name: str
    ports: list[BoardPort] = field(default_factory=list)


@dataclass
class SystemModel:
    name: str
    board: Board
    clocks: list[ClockDomain] = field(default_factory=list)
    resets: list[ResetDomain] = field(default_factory=list)
    peripherals: list[PeripheralInstance] = field(default_factory=list)
    memory_regions: list[AddressRegion] = field(default_factory=list)
    options: dict[str, Any] = field(default_factory=dict)
```

Toto je presne tá vrstva, ktorá dnes chýba v striktnej, jednotnej forme. V súčasnom kóde sú dobré stavebné bloky, ale model je zjavne rozptýlený medzi generátormi a externými modulmi.

---

## 5. Plugin systém

### `api/plugin.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field
from typing import Protocol, Any

from socfw.domain.model import SystemModel
from socfw.api.diagnostics import Diagnostic


class ValidationRule(Protocol):
    code_prefix: str
    def validate(self, model: SystemModel) -> list[Diagnostic]:
        ...


class Emitter(Protocol):
    family: str
    def emit(self, ctx: Any, ir: Any) -> list[Any]:
        ...


class BusPlanner(Protocol):
    protocol: str
    def plan(self, model: SystemModel) -> Any:
        ...


@dataclass
class PluginRegistry:
    validators: list[ValidationRule] = field(default_factory=list)
    emitters: dict[str, Emitter] = field(default_factory=dict)
    bus_planners: dict[str, BusPlanner] = field(default_factory=dict)
    board_plugins: dict[str, Any] = field(default_factory=dict)
    ip_plugins: dict[str, Any] = field(default_factory=dict)

    def register_validator(self, rule: ValidationRule) -> None:
        self.validators.append(rule)

    def register_emitter(self, emitter: Emitter) -> None:
        self.emitters[emitter.family] = emitter

    def register_bus_planner(self, planner: BusPlanner) -> None:
        self.bus_planners[planner.protocol] = planner
```

Takto sa zbavíš budúceho `if bus_type == "simple_bus"` štýlu v core.

---

## 6. Validácia

### `validate/runner.py`

```python
from __future__ import annotations

from socfw.api.diagnostics import Diagnostic
from socfw.api.plugin import PluginRegistry
from socfw.domain.model import SystemModel


class ValidationRunner:
    def __init__(self, registry: PluginRegistry):
        self.registry = registry

    def run(self, model: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []
        for rule in self.registry.validators:
            diags.extend(rule.validate(model))
        return diags
```

### `validate/rules/addresses.py`

```python
from __future__ import annotations

from socfw.api.diagnostics import Diagnostic, Severity
from socfw.domain.model import SystemModel


class AddressOverlapRule:
    code_prefix = "ADR"

    def validate(self, model: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []

        regions = []
        for p in model.peripherals:
            if p.bus and p.bus.region:
                regions.append((p.inst_name, p.bus.region))

        for i, (a_name, a) in enumerate(regions):
            for b_name, b in regions[i + 1:]:
                if not (a.end < b.base or b.end < a.base):
                    diags.append(
                        Diagnostic(
                            code="ADR001",
                            severity=Severity.ERROR,
                            message=(
                                f"Address overlap between {a_name} "
                                f"(0x{a.base:08X}-0x{a.end:08X}) and {b_name} "
                                f"(0x{b.base:08X}-0x{b.end:08X})"
                            ),
                            subject="address map",
                            related=(a_name, b_name),
                        )
                    )
        return diags
```

### `validate/rules/board.py`

```python
from __future__ import annotations

from socfw.api.diagnostics import Diagnostic, Severity
from socfw.domain.model import SystemModel


class DuplicateBoardPortRule:
    code_prefix = "BRD"

    def validate(self, model: SystemModel) -> list[Diagnostic]:
        seen: set[str] = set()
        diags: list[Diagnostic] = []

        for port in model.board.ports:
            if port.name in seen:
                diags.append(
                    Diagnostic(
                        code="BRD001",
                        severity=Severity.ERROR,
                        message=f"Duplicate board port: {port.name}",
                        subject="board ports",
                        related=(port.name,),
                    )
                )
            seen.add(port.name)

        return diags
```

Toto je modernejší nástupca validácie, ktorú dnes robí `RtlBuilder.validate()`, len presunutý na správne miesto a všeobecnejšie.

---

## 7. Elaboration vrstva

### `elaborate/pipeline.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field
from typing import Any

from socfw.domain.model import SystemModel


@dataclass
class PlanningDecision:
    category: str
    message: str
    rationale: str
    related: list[str] = field(default_factory=list)


@dataclass
class ElaboratedSystem:
    model: SystemModel
    bus_plan: Any = None
    board_port_plan: Any = None
    clock_plan: Any = None
    reset_plan: Any = None
    dependencies: list[str] = field(default_factory=list)
    decisions: list[PlanningDecision] = field(default_factory=list)


class Elaborator:
    def __init__(self, registry):
        self.registry = registry

    def elaborate(self, model: SystemModel) -> ElaboratedSystem:
        es = ElaboratedSystem(model=model)

        protocols = {p.bus.protocol for p in model.peripherals if p.bus}
        for proto in protocols:
            planner = self.registry.bus_planners.get(proto)
            if planner is None:
                continue
            es.bus_plan = planner.plan(model)
            es.decisions.append(
                PlanningDecision(
                    category="bus",
                    message=f"Planned interconnect for protocol {proto}",
                    rationale="Selected registered bus planner from plugin registry",
                    related=[proto],
                )
            )
        return es
```

---

## 8. IR vrstvy

### `ir/rtl.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class RtlWire:
    name: str
    width: int = 1
    comment: str = ""


@dataclass(frozen=True)
class RtlAssign:
    lhs: str
    rhs: str
    kind: str = "comb"
    comment: str = ""


@dataclass(frozen=True)
class RtlPort:
    name: str
    direction: str
    width: int = 1


@dataclass(frozen=True)
class RtlConnection:
    port: str
    signal: str


@dataclass
class RtlInstance:
    module: str
    name: str
    params: dict[str, str] = field(default_factory=dict)
    conns: list[RtlConnection] = field(default_factory=list)
    comment: str = ""


@dataclass
class RtlModule:
    name: str
    ports: list[RtlPort] = field(default_factory=list)
    wires: list[RtlWire] = field(default_factory=list)
    assigns: list[RtlAssign] = field(default_factory=list)
    instances: list[RtlInstance] = field(default_factory=list)


@dataclass
class RtlIR:
    top: RtlModule
    support_modules: list[RtlModule] = field(default_factory=list)
    extra_sources: list[str] = field(default_factory=list)
```

Toto je priamy duch dnešného `RtlContext`, len očistený a pripravený ako stabilné IR API.

### `ir/timing.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class TimingClock:
    name: str
    port: str
    period_ns: float


@dataclass(frozen=True)
class FalsePath:
    src: str
    dst: str
    comment: str = ""


@dataclass
class TimingIR:
    clocks: list[TimingClock] = field(default_factory=list)
    false_paths: list[FalsePath] = field(default_factory=list)
```

### `ir/software.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class SwRegister:
    peripheral: str
    name: str
    addr: int
    access: str
    desc: str = ""


@dataclass
class SoftwareIR:
    sys_clk_hz: int
    ram_base: int
    ram_size: int
    registers: list[SwRegister] = field(default_factory=list)
    irqs: dict[str, int] = field(default_factory=dict)
```

Takto sa `soc_map.h`, linker script aj markdown mapa generujú z jedného IR, nie priamo z doménového modelu. Dnešný `SWGenerator` je na to dobrá inšpirácia, ale nie ešte finálna architektúra.

---

## 9. IR buildery

### `build/context.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field
from pathlib import Path

from socfw.api.plugin import PluginRegistry


@dataclass
class BuildContext:
    out_dir: Path
    registry: PluginRegistry
```

### `build/request.py`

```python
from dataclasses import dataclass, field


@dataclass
class BuildRequest:
    project_file: str
    out_dir: str
    artifact_families: list[str] = field(
        default_factory=lambda: ["rtl", "timing", "software", "board", "docs"]
    )
```

### `build/manifest.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field


@dataclass
class GeneratedArtifact:
    path: str
    family: str
    generator: str
    metadata: dict = field(default_factory=dict)


@dataclass
class BuildManifest:
    artifacts: list[GeneratedArtifact] = field(default_factory=list)
```

### `build/pipeline.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field
from pathlib import Path

from socfw.api.result import Result
from socfw.api.diagnostics import Diagnostic, Severity
from socfw.api.plugin import PluginRegistry
from socfw.build.context import BuildContext
from socfw.build.request import BuildRequest
from socfw.build.manifest import BuildManifest
from socfw.config.loader import ConfigLoader
from socfw.domain.model import SystemModel, Board
from socfw.elaborate.pipeline import Elaborator
from socfw.validate.runner import ValidationRunner


@dataclass
class BuildResult:
    ok: bool
    diagnostics: list[Diagnostic] = field(default_factory=list)
    manifest: BuildManifest = field(default_factory=BuildManifest)


class BuildPipeline:
    def __init__(self, registry: PluginRegistry):
        self.registry = registry
        self.loader = ConfigLoader()
        self.validator = ValidationRunner(registry)
        self.elaborator = Elaborator(registry)

    def normalize(self, raw_bundle) -> Result[SystemModel]:
        # placeholder: tu príde normálny normalizer
        model = SystemModel(
            name="example_soc",
            board=Board(name="qmtech_ep4ce55"),
        )
        return Result(value=model)

    def build(self, req: BuildRequest) -> BuildResult:
        all_diags: list[Diagnostic] = []

        raw_res = self.loader.load(req.project_file)
        all_diags.extend(raw_res.diagnostics)
        if not raw_res.ok:
            return BuildResult(ok=False, diagnostics=all_diags)

        norm_res = self.normalize(raw_res.require())
        all_diags.extend(norm_res.diagnostics)
        if not norm_res.ok:
            return BuildResult(ok=False, diagnostics=all_diags)

        model = norm_res.require()
        all_diags.extend(self.validator.run(model))
        if any(d.severity == Severity.ERROR for d in all_diags):
            return BuildResult(ok=False, diagnostics=all_diags)

        elaborated = self.elaborator.elaborate(model)
        ctx = BuildContext(out_dir=Path(req.out_dir), registry=self.registry)
        manifest = BuildManifest()

        # sem pôjdu IR buildery + emitters
        for family in req.artifact_families:
            emitter = self.registry.emitters.get(family)
            if emitter is None:
                continue
            # TODO: build corresponding IR
            artifacts = emitter.emit(ctx, elaborated)
            manifest.artifacts.extend(artifacts)

        return BuildResult(ok=True, diagnostics=all_diags, manifest=manifest)
```

Toto je presne jadro, ktoré dnes v zjednotenej forme chýba.

---

## 10. Emitre

### `emit/base.py`

```python
from __future__ import annotations
from typing import Protocol, Any

from socfw.build.context import BuildContext
from socfw.build.manifest import GeneratedArtifact


class BaseEmitter(Protocol):
    family: str
    def emit(self, ctx: BuildContext, ir: Any) -> list[GeneratedArtifact]:
        ...
```

### `emit/renderer.py`

```python
from __future__ import annotations
from pathlib import Path
from jinja2 import Environment, FileSystemLoader, StrictUndefined


class Renderer:
    def __init__(self, templates_dir: str):
        self.env = Environment(
            loader=FileSystemLoader(templates_dir),
            undefined=StrictUndefined,
            trim_blocks=True,
            lstrip_blocks=True,
            keep_trailing_newline=True,
        )

    def render(self, template_name: str, **ctx) -> str:
        tmpl = self.env.get_template(template_name)
        return tmpl.render(**ctx)

    def write_text(self, path: Path, content: str, encoding: str = "utf-8") -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding=encoding)
```

Toto je nástupca dnešného `base.py`, ale bez globálnej politiky „všetko na ASCII a zvyšok zahodiť“. To by som nechal rozhodovať per emitter/artifact.

### `emit/software_emitter.py`

```python
from __future__ import annotations
from pathlib import Path

from socfw.build.manifest import GeneratedArtifact
from socfw.emit.renderer import Renderer


class SoftwareEmitter:
    family = "software"

    def __init__(self, templates_dir: str):
        self.renderer = Renderer(templates_dir)

    def emit(self, ctx, ir) -> list[GeneratedArtifact]:
        out = ctx.out_dir / "sw" / "soc_map.h"
        content = self.renderer.render("soc_map.h.j2", ir=ir)
        self.renderer.write_text(out, content, encoding="utf-8")
        return [
            GeneratedArtifact(
                path=str(out),
                family=self.family,
                generator=self.__class__.__name__,
            )
        ]
```

Dnešné `SWGenerator` a šablóny sa dajú na toto relatívne ľahko namapovať.

---

## 11. Builtin plugin príklad: bus

### `plugins/builtin/buses/simple_bus.py`

```python
from __future__ import annotations
from dataclasses import dataclass

from socfw.api.plugin import BusPlanner, PluginRegistry


@dataclass
class SimpleBusPlan:
    protocol: str
    slaves: list[str]


class SimpleBusPlanner:
    protocol = "simple_bus"

    def plan(self, model):
        slaves = [
            p.inst_name
            for p in model.peripherals
            if p.bus and p.bus.protocol == self.protocol and p.bus.role == "slave"
        ]
        return SimpleBusPlan(protocol=self.protocol, slaves=slaves)


def register(reg: PluginRegistry) -> None:
    reg.register_bus_planner(SimpleBusPlanner())
```

To je banálny skeleton, ale ukazuje miesto, kde sa budú pridávať nové bus-y.

---

## 12. Builtin plugin príklad: board

### `plugins/builtin/boards/qmtech_ep4ce55.py`

```python
from __future__ import annotations
from socfw.domain.enums import PortDir
from socfw.domain.model import Board, BoardPort


def create_board() -> Board:
    return Board(
        name="qmtech_ep4ce55",
        ports=[
            BoardPort(name="SYS_CLK", direction=PortDir.INPUT, width=1, io_standard="3.3-V LVTTL"),
            BoardPort(name="RESET_N", direction=PortDir.INPUT, width=1, io_standard="3.3-V LVTTL"),
            BoardPort(name="UART_TX", direction=PortDir.OUTPUT, width=1, io_standard="3.3-V LVTTL"),
            BoardPort(name="UART_RX", direction=PortDir.INPUT, width=1, io_standard="3.3-V LVTTL"),
        ],
    )
```

Súčasný `tcl.py` drží board pin databázu priamo v generátore. To by som presunul práve sem, do board pluginu/deskriptora.

---

## 13. Registry bootstrap

### `__init__.py` alebo `engine.py`

```python
from socfw.api.plugin import PluginRegistry
from socfw.plugins.builtin.buses import simple_bus
from socfw.emit.software_emitter import SoftwareEmitter
from socfw.validate.rules.addresses import AddressOverlapRule
from socfw.validate.rules.board import DuplicateBoardPortRule


def create_builtin_registry() -> PluginRegistry:
    reg = PluginRegistry()

    reg.register_validator(AddressOverlapRule())
    reg.register_validator(DuplicateBoardPortRule())

    simple_bus.register(reg)

    reg.register_emitter(SoftwareEmitter("templates/software"))
    # sem neskôr rtl/timing/board/docs emittery

    return reg
```

---

## 14. CLI

### `cli/main.py`

```python
from __future__ import annotations
import argparse

from socfw.build.pipeline import BuildPipeline
from socfw.build.request import BuildRequest
from socfw import create_builtin_registry


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    b = sub.add_parser("build")
    b.add_argument("project")
    b.add_argument("--out", default="build/gen")

    v = sub.add_parser("validate")
    v.add_argument("project")

    args = ap.parse_args()

    registry = create_builtin_registry()
    pipeline = BuildPipeline(registry)

    if args.cmd == "build":
        result = pipeline.build(BuildRequest(project_file=args.project, out_dir=args.out))
        for d in result.diagnostics:
            print(f"{d.severity.value.upper()} {d.code}: {d.message}")
        return 0 if result.ok else 1

    if args.cmd == "validate":
        result = pipeline.build(BuildRequest(
            project_file=args.project,
            out_dir=".socfw_validate_tmp",
            artifact_families=[],
        ))
        for d in result.diagnostics:
            print(f"{d.severity.value.upper()} {d.code}: {d.message}")
        return 0 if result.ok else 1

    return 1
```

---

## 15. Čo by som preniesol zo starého kódu priamo do nového skeletonu

### Takmer priamo

* `RtlContext` myšlienku do `ir/rtl.py`,
* validačnú logiku z `RtlBuilder.validate()` rozdeliť do pravidiel,
* `SWGenerator` mapovanie registrov, IRQ a linker info do `SoftwareIRBuilder`,
* `SDCGenerator` transformačnú logiku do `TimingIRBuilder`,
* `tcl.py` board pin databázu do board pluginu.

### Neponechal by som v tej istej forme

* legacy SoC context bridge v `rtl.py`,
* shared ASCII-dropping write policy v `base.py`,
* ad-hoc stringové prepojenia medzi generátorom a názvom template súboru, lebo presne tam dnes vidno aj konkrétny bug s `periph_regs.sv.j2` vs `reg_block.sv.j2`.

---

## 16. Prvé 4 implementačné kroky

Ak by si to začal robiť hneď, šiel by som v tomto poradí:

1. **zaviesť `Diagnostic`, `Result`, `BuildPipeline` a `PluginRegistry`**
   Toto je kostra.

2. **spraviť centrálny `ConfigLoader` + `SystemModel` normalizer**
   Tým odstrániš chaos pri YAML vstupoch.

3. **presunúť existujúcu RTL validáciu do `validate/rules/*`**
   Najrýchlejší zisk kvality.

4. **spraviť prvý čistý `SoftwareIRBuilder` a `SoftwareEmitter`**
   Software artefakty sú jednoduchšie než full RTL a rýchlo overia architektúru.

Ak bude tento krok fungovať, potom:

* `TimingIRBuilder`,
* `RtlIRBuilder`,
* board emitter,
* reporty.

---

## 17. Najkratší praktický verdict

Tento skeleton ti dá:

* centrálny config frontend,
* čistý build lifecycle,
* plugin body pre bus-y/IP/boardy,
* jednotnú validáciu,
* stabilné IR vrstvy,
* emitter model namiesto „skriptov“.

A pritom stále zachováva to najlepšie, čo dnešný framework už naznačuje:
**logika v builderoch, nie v templatoch; deterministické generovanie; jeden source of truth pre HW/SW/docs.**

V ďalšom kroku ti viem pripraviť už úplne konkrétne:
**návrh YAML schém v2** alebo **migračný plán zo súčasného frameworku na tento nový skeleton**.
