Dobre — poďme už na **návrh kódu jadra**, nie migráciu.

Z tvojich súborov je už jasné, aké reality musí nové jadro zvládnuť:

* shared board descriptor má byť zdroj hardvérových faktov o kite, nie projektový config,
* project config nesie design intent, feature enablement, modulové inštancie a clock bindingy,
* timing config musí vedieť modelovať clocks, PLL outputs, clock groups a IO overrides,
* vendor IP ako `clkpll` a `sdram_fifo` nie sú len ploché RTL súbory, ale asset bundle s reset/clock semantikou.
* súčasné generovanie RTL je už čiastočne IR-based, ale SoC vetva má ešte legacy bridge, ktorý treba v novom návrhu odstrániť.

Nižšie dávam návrh ďalšieho kroku ako **reálny core architecture plan**.

---

# 1. Čo by som implementoval ako prvé

Nie všetko naraz. Šiel by som v tomto poradí:

### Fáza A — core contracts

* `Diagnostic`
* `Result`
* `BuildRequest`
* `BuildContext`
* `PluginRegistry`

### Fáza B — canonical domain model

* `BoardModel`
* `ProjectModel`
* `IpDescriptor`
* `TimingModel`
* `SystemModel`

### Fáza C — validation

* referencie na board resources
* unique names
* clock domain consistency
* vendor IP asset validity
* port width/binding validity

### Fáza D — elaboration

* board resource resolution
* external port binding plan
* clock plan
* reset plan
* dependency asset plan

### Fáza E — IR builders

* `BoardIRBuilder`
* `TimingIRBuilder`
* `RtlIRBuilder`

Až potom emitre.

---

# 2. Nové jadro: balíky a zodpovednosti

Odporúčaná kostra:

```text
socfw/
  core/
    diagnostics.py
    result.py
    ids.py

  config/
    loader.py
    project_schema.py
    board_schema.py
    timing_schema.py
    ip_schema.py

  model/
    board.py
    project.py
    timing.py
    ip.py
    system.py

  validate/
    engine.py
    rules/

  elaborate/
    planner.py
    board_bindings.py
    clocks.py
    resets.py
    assets.py

  ir/
    rtl.py
    timing.py
    board.py

  builders/
    system_builder.py
    rtl_ir_builder.py
    timing_ir_builder.py
    board_ir_builder.py

  plugins/
    registry.py
    builtin/
      quartus.py
      boards/
      ip/
      buses/

  emit/
    rtl/
    timing/
    board/

  build/
    pipeline.py
    context.py
    manifest.py
```

---

# 3. Core contracts

## `core/diagnostics.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field
from enum import Enum


class Severity(str, Enum):
    INFO = "info"
    WARNING = "warning"
    ERROR = "error"


@dataclass(frozen=True)
class SourceRef:
    file: str
    path: str | None = None
    line: int | None = None
    column: int | None = None


@dataclass(frozen=True)
class Diagnostic:
    code: str
    severity: Severity
    message: str
    subject: str
    refs: tuple[SourceRef, ...] = ()
    hints: tuple[str, ...] = ()
```

## `core/result.py`

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
```

Toto musí nahradiť dnešný pattern `print(...)` + `sys.exit(1)` v core logike. Súčasný `rtl.py` to ešte robí priamo, čo je presne vec, ktorú by som už v novom jadre nechcel.

---

# 4. Doménový model

Tu by som to rozdelil na 5 hlavných modelov.

## `model/board.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field
from enum import Enum


class PortDir(str, Enum):
    INPUT = "input"
    OUTPUT = "output"
    INOUT = "inout"


@dataclass(frozen=True)
class BoardScalarSignal:
    name: str
    top_name: str
    direction: PortDir
    io_standard: str | None = None
    pin: str | None = None
    weak_pull_up: bool = False


@dataclass(frozen=True)
class BoardVectorSignal:
    name: str
    top_name: str
    direction: PortDir
    width: int
    io_standard: str | None = None
    pins: dict[int, str] = field(default_factory=dict)
    weak_pull_up: bool = False


@dataclass(frozen=True)
class BoardResource:
    key: str                   # "leds", "buttons", "sdram", ...
    kind: str                  # gpio_out, uart, sdram, ...
    scalars: dict[str, BoardScalarSignal] = field(default_factory=dict)
    vectors: dict[str, BoardVectorSignal] = field(default_factory=dict)
    meta: dict[str, object] = field(default_factory=dict)


@dataclass(frozen=True)
class BoardConnectorRole:
    key: str                   # "led8"
    top_name: str
    direction: PortDir
    width: int
    io_standard: str | None = None
    pins: dict[int, str] = field(default_factory=dict)


@dataclass(frozen=True)
class BoardConnector:
    key: str                   # "J10"
    roles: dict[str, BoardConnectorRole] = field(default_factory=dict)


@dataclass(frozen=True)
class BoardModel:
    board_id: str
    fpga_family: str
    fpga_part: str
    sys_clk: BoardScalarSignal
    sys_reset: BoardScalarSignal
    onboard: dict[str, BoardResource] = field(default_factory=dict)
    connectors: dict[str, BoardConnector] = field(default_factory=dict)
    metadata: dict[str, object] = field(default_factory=dict)
```

Toto sedí na tvoj board descriptor: systémový clock/reset, onboard resource bundle a connector roles. Dôležité je, že board ostáva shared hardware fact model.

---

## `model/ip.py`

Tu by som zaviedol explicitné rozlíšenie source IP vs vendor-generated IP.

```python
from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class IpOrigin:
    kind: str          # "source", "vendor_generated", "generated"
    tool: str | None = None
    packaging: str | None = None


@dataclass(frozen=True)
class IpArtifactBundle:
    synthesis: tuple[str, ...] = ()
    simulation: tuple[str, ...] = ()
    metadata: tuple[str, ...] = ()


@dataclass(frozen=True)
class IpClockOutput:
    port: str
    kind: str                  # generated_clock, status
    default_domain: str | None = None
    signal_name: str | None = None


@dataclass(frozen=True)
class IpResetSemantics:
    port: str | None
    active_high: bool = False
    bypass_sync: bool = False
    optional: bool = False
    asynchronous: bool = False


@dataclass(frozen=True)
class IpClocking:
    primary_input_port: str | None = None
    additional_input_ports: tuple[str, ...] = ()
    outputs: tuple[IpClockOutput, ...] = ()


@dataclass(frozen=True)
class IpDescriptor:
    name: str
    module: str
    category: str                 # standalone, peripheral, dependency, ...
    origin: IpOrigin
    needs_bus: bool
    generate_registers: bool
    instantiate_directly: bool
    dependency_only: bool
    reset: IpResetSemantics
    clocking: IpClocking
    artifacts: IpArtifactBundle
    meta: dict[str, object] = field(default_factory=dict)
```

Toto je dôležité hlavne kvôli `clkpll` a `sdram_fifo`:

* `clkpll` potrebuje explicitné `bypass_sync`, active-high reset a clock outputs,
* `sdram_fifo` je dependency-style vendor IP s atypickým resetom a dual-clock semantikou.

---

## `model/project.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class PortBinding:
    port_name: str
    target: str                  # napr. board:onboard.leds
    top_name: str | None = None
    width: int | None = None
    adapt: str | None = None     # zero, replicate, high_z


@dataclass(frozen=True)
class ClockBinding:
    port_name: str
    domain: str
    no_reset: bool = False


@dataclass
class ModuleInstance:
    instance: str
    type_name: str
    params: dict[str, object] = field(default_factory=dict)
    clocks: list[ClockBinding] = field(default_factory=list)
    port_bindings: list[PortBinding] = field(default_factory=list)


@dataclass(frozen=True)
class GeneratedClockRequest:
    domain: str
    source_instance: str
    source_output: str
    frequency_hz: int | None = None
    sync_from: str | None = None
    sync_stages: int | None = None
    no_reset: bool = False


@dataclass
class ProjectModel:
    name: str
    mode: str
    board_ref: str
    registries_ip: list[str] = field(default_factory=list)
    feature_refs: list[str] = field(default_factory=list)
    modules: list[ModuleInstance] = field(default_factory=list)
    primary_clock_domain: str = "sys_clk"
    generated_clocks: list[GeneratedClockRequest] = field(default_factory=list)
    timing_file: str | None = None
    debug: bool = False
```

Toto priamo sedí na tvoje existujúce projekty:

* `board_ref`, `plugins.ip` / `paths.ip_plugins`, `modules`, `clock_domains`, `port_overrides`, `timing.file`.

---

## `model/timing.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class TimingPrimaryClock:
    name: str
    source_port: str
    period_ns: float
    uncertainty_ns: float | None = None
    reset_port: str | None = None
    reset_active_low: bool = True
    reset_sync_stages: int = 2


@dataclass(frozen=True)
class TimingGeneratedClock:
    name: str
    source_instance: str
    source_clock: str
    pin_index: int | None
    multiply_by: int
    divide_by: int
    phase_shift_ps: int | None = None
    sync_from: str | None = None
    sync_stages: int | None = None


@dataclass(frozen=True)
class ClockGroupConstraint:
    group_type: str
    groups: list[list[str]]


@dataclass(frozen=True)
class IoDelayOverride:
    port: str
    direction: str
    clock: str
    max_ns: float
    min_ns: float | None = None


@dataclass
class TimingModel:
    primary_clocks: list[TimingPrimaryClock] = field(default_factory=list)
    generated_clocks: list[TimingGeneratedClock] = field(default_factory=list)
    clock_groups: list[ClockGroupConstraint] = field(default_factory=list)
    io_auto: bool = True
    io_default_clock: str | None = None
    io_default_input_max_ns: float | None = None
    io_default_output_max_ns: float | None = None
    io_overrides: list[IoDelayOverride] = field(default_factory=list)
    derive_uncertainty: bool = True
```

Toto sedí na tvoje dnešné timing configy vrátane SDRAM PLL a IO overrides.

---

## `model/system.py`

```python
from __future__ import annotations
from dataclasses import dataclass

from .board import BoardModel
from .project import ProjectModel
from .timing import TimingModel
from .ip import IpDescriptor


@dataclass
class SystemModel:
    board: BoardModel
    project: ProjectModel
    timing: TimingModel | None
    ip_catalog: dict[str, IpDescriptor]
```

---

# 5. Validation engine

## `validate/engine.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field

from socfw.core.diagnostics import Diagnostic
from socfw.model.system import SystemModel


class ValidationRule:
    def validate(self, system: SystemModel) -> list[Diagnostic]:
        raise NotImplementedError


@dataclass
class ValidationEngine:
    rules: list[ValidationRule] = field(default_factory=list)

    def run(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []
        for rule in self.rules:
            diags.extend(rule.validate(system))
        return diags
```

### Prvé pravidlá, ktoré by som fakt implementoval hneď

* `UnknownBoardFeatureRule`
* `UnknownBoardBindingTargetRule`
* `UnknownIpTypeRule`
* `UnknownClockDomainRule`
* `DuplicateModuleInstanceRule`
* `VendorIpArtifactExistsRule`
* `GeneratedClockSourceRule`
* `BindingWidthCompatibilityRule`

### Prečo práve tieto

Lebo presne tieto veci sa objavujú v tvojich projektoch:

* board resource refs,
* generated clocks z `clkpll`,
* width adaptation pre PMOD,
* dependency assety typu `qip`.

---

# 6. Elaboration layer

Toto je ďalší zásadný krok. Zo `SystemModel` nevieš ešte generovať RTL alebo board TCL priamo. Najprv treba urobiť plán.

## `elaborate/planner.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class ResolvedPortBinding:
    instance: str
    port_name: str
    target_ref: str
    resolved_top_name: str
    resolved_direction: str
    resolved_width: int
    adapt: str | None = None


@dataclass(frozen=True)
class ResolvedClockDomain:
    name: str
    frequency_hz: int | None
    source_kind: str           # board, generated
    source_ref: str
    reset_policy: str          # synced, bypassed, none


@dataclass(frozen=True)
class ResolvedDependencyAsset:
    logical_name: str
    synthesis_files: tuple[str, ...]
    simulation_files: tuple[str, ...]
    metadata_files: tuple[str, ...]


@dataclass
class ElaboratedDesign:
    system: object
    port_bindings: list[ResolvedPortBinding] = field(default_factory=list)
    clock_domains: list[ResolvedClockDomain] = field(default_factory=list)
    dependency_assets: list[ResolvedDependencyAsset] = field(default_factory=list)
```

## `elaborate/board_bindings.py`

Sem by som dal logiku:

* `board:onboard.leds` → `ONB_LEDS`, width 6
* `board:connector.pmod.J10.role.led8` → `PMOD_J10`, width 8
* `board:onboard.sdram` → bundle scalar/vector signálov

## `elaborate/clocks.py`

Sem by som dal:

* primary board clock domain
* generated clock requests z projektu
* validáciu, že `clkpll` naozaj exportuje `c0`, `c1` ako outputs
* reset policy:

  * board primary clock → synced reset
  * `bypass_sync` pre PLL reset input
  * `no_reset: true` pri shifted SDRAM clocku

To presne potrebuje tvoj `clkpll` a SDRAM projekt.

## `elaborate/assets.py`

Sem patrí:

* vendor-generated IP asset bundle resolution
* transitive dependency asset inclusion
* flattening do syntéznej množiny súborov pre Quartus

To je miesto, kde sa `clkpll.qip` a `sdram_fifo.qip` dostanú do build manifestu bez toho, aby sa tvárili ako obyčajné ručné RTL cores.

---

# 7. IR vrstvy

Navrhujem tri prvé IR vrstvy.

## `ir/board.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class BoardPinAssignment:
    top_name: str
    index: int | None
    pin: str
    io_standard: str | None = None
    weak_pull_up: bool = False


@dataclass
class BoardIR:
    family: str
    device: str
    assignments: list[BoardPinAssignment] = field(default_factory=list)
```

Toto nahradí dnešné hardcodované `_ONB_PINS`, `_PMOD_PINS` a pod. v `tcl.py`; tie majú byť v board plugin modeli, nie v generátore.

## `ir/timing.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class ClockConstraint:
    name: str
    source: str
    period_ns: float


@dataclass(frozen=True)
class GeneratedClockConstraint:
    name: str
    source_instance: str
    pin_index: int | None
    multiply_by: int
    divide_by: int
    phase_shift_ps: int | None = None


@dataclass
class TimingIR:
    clocks: list[ClockConstraint] = field(default_factory=list)
    generated_clocks: list[GeneratedClockConstraint] = field(default_factory=list)
    clock_groups: list[dict] = field(default_factory=list)
    io_delays: list[dict] = field(default_factory=list)
    false_paths: list[dict] = field(default_factory=list)
```

## `ir/rtl.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class RtlPort:
    name: str
    direction: str
    width: int = 1


@dataclass(frozen=True)
class RtlWire:
    name: str
    width: int = 1
    comment: str = ""


@dataclass(frozen=True)
class RtlAssign:
    lhs: str
    rhs: str
    direction: str = "comb"
    comment: str = ""


@dataclass(frozen=True)
class RtlConn:
    port: str
    signal: str


@dataclass
class RtlInstance:
    module: str
    name: str
    params: dict[str, object] = field(default_factory=dict)
    conns: list[RtlConn] = field(default_factory=list)


@dataclass
class RtlModuleIR:
    name: str
    ports: list[RtlPort] = field(default_factory=list)
    wires: list[RtlWire] = field(default_factory=list)
    assigns: list[RtlAssign] = field(default_factory=list)
    instances: list[RtlInstance] = field(default_factory=list)
    extra_sources: list[str] = field(default_factory=list)
```

Tu môžeš veľa reuse-núť z dnešného `RtlContext` / `RtlBuilder`, len bez legacy mosta a s čistejším vstupom.

---

# 8. Builder API

## `builders/system_builder.py`

```python
from __future__ import annotations

from socfw.model.system import SystemModel
from socfw.core.result import Result


class SystemBuilder:
    def build(self, board, project, timing, ip_catalog) -> Result[SystemModel]:
        return Result(
            value=SystemModel(
                board=board,
                project=project,
                timing=timing,
                ip_catalog=ip_catalog,
            )
        )
```

## `builders/board_ir_builder.py`

```python
class BoardIRBuilder:
    def build(self, design) -> BoardIR:
        ...
```

## `builders/timing_ir_builder.py`

```python
class TimingIRBuilder:
    def build(self, design) -> TimingIR:
        ...
```

## `builders/rtl_ir_builder.py`

```python
class RtlIRBuilder:
    def build(self, design) -> RtlModuleIR:
        ...
```

Kľúčové pravidlo:
**všetky 3 buildre berú `ElaboratedDesign`, nie raw project YAML ani `SystemModel`.**

---

# 9. Plugin registry

## `plugins/registry.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field


@dataclass
class PluginRegistry:
    board_loaders: dict[str, object] = field(default_factory=dict)
    ip_loaders: list[object] = field(default_factory=list)
    validators: list[object] = field(default_factory=list)
    emitters: dict[str, object] = field(default_factory=dict)
```

### Čo by som registroval ako builtin pluginy hneď

* `QuartusBoardEmitter`
* `QuartusFilesEmitter`
* `QuartusTimingEmitter`
* `YamlBoardLoader`
* `YamlIpLoader`

Neskôr:

* `SimpleBusPlugin`
* `AxiLitePlugin`

---

# 10. Build pipeline

## `build/pipeline.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field

from socfw.core.diagnostics import Diagnostic
from socfw.core.result import Result
from socfw.validate.engine import ValidationEngine
from socfw.elaborate.planner import ElaboratedDesign


@dataclass
class BuildRequest:
    project_file: str
    out_dir: str


@dataclass
class BuildResult:
    ok: bool
    diagnostics: list[Diagnostic] = field(default_factory=list)
    artifacts: list[str] = field(default_factory=list)


class BuildPipeline:
    def __init__(self, loaders, validators, planners, builders, emitters):
        self.loaders = loaders
        self.validators = validators
        self.planners = planners
        self.builders = builders
        self.emitters = emitters

    def run(self, req: BuildRequest) -> BuildResult:
        diags: list[Diagnostic] = []

        board = self.loaders.load_board(...)
        project = self.loaders.load_project(...)
        timing = self.loaders.load_timing(...)
        ip_catalog = self.loaders.load_ip_catalog(...)

        system = self.builders.system.build(board, project, timing, ip_catalog)
        diags.extend(system.diagnostics)
        if not system.ok:
            return BuildResult(ok=False, diagnostics=diags)

        diags.extend(self.validators.run(system.value))
        if any(d.severity.value == "error" for d in diags):
            return BuildResult(ok=False, diagnostics=diags)

        design: ElaboratedDesign = self.planners.elaborate(system.value)

        board_ir = self.builders.board_ir.build(design)
        timing_ir = self.builders.timing_ir.build(design)
        rtl_ir = self.builders.rtl_ir.build(design)

        artifacts = []
        artifacts.extend(self.emitters.board.emit(board_ir, req.out_dir))
        artifacts.extend(self.emitters.timing.emit(timing_ir, req.out_dir))
        artifacts.extend(self.emitters.rtl.emit(rtl_ir, req.out_dir))

        return BuildResult(ok=True, diagnostics=diags, artifacts=artifacts)
```

---

# 11. Čo konkrétne prebrať zo starého kódu a kam

## Zobrať a presunúť

* logiku width adaptation z `rtl_builder._connect_port()` do novej elaboration/RTL IR vrstvy, lebo je vecne správna a už rieši `zero`, `replicate`, `high_z`.
* timing IO auto/override logiku zo `sdc.py` do `TimingIRBuilder`, lebo je to presne typ transformačnej logiky, ktorá má byť pred emitterom.
* myšlienku „board ports sa majú injectovať len ak ich projekt skutočne potrebuje“ z `rtl.py`, ale už ju robiť v elaboration vrstve, nie v generátore.
* flat static board TCL emitter koncept z `tcl.py`, ale bez hardcoded BSP databázy v samotnom generátore.

## Nechať za sebou

* legacy SoC context bridge v RTL.
* hardcoded pin DB v `tcl.py` ako single source of truth; to má byť v board descriptor/plugin modeli.
* `print` + `sys.exit` v core.

---

# 12. Moje odporúčanie na najbližší implementačný krok

Keby som mal povedať **jednu vec**, ktorú má zmysel hneď napísať ako prvú, tak je to:

### `SystemModel + ValidationEngine + ElaboratedDesign`

Konkrétne:

1. parsery pre `board/project/timing/ip`
2. `SystemModel`
3. 5–7 validačných pravidiel
4. resolver board resource bindings
5. resolver generated clocks z vendor IP

To ti dá okamžite funkčné jadro, na ktoré potom prirodzene sadne:

* `BoardIRBuilder`
* `TimingIRBuilder`
* `RtlIRBuilder`

A budeš vedieť veľmi skoro overiť aj tvoje tri referenčné projekty:

* blink_test_01
* blink_test_02
* sdram_test

---

# 13. Môj stručný návrh ďalšieho kroku

Navrhujem pokračovať takto:

**ďalšia správa = konkrétny návrh Python súborov s reálnym kódom pre**

* `model/board.py`
* `model/project.py`
* `model/ip.py`
* `model/timing.py`
* `validate/rules/*.py`
* `elaborate/board_bindings.py`
* `elaborate/clocks.py`

Teda nie už len architektúra, ale priamo prvý implementovateľný balík.
