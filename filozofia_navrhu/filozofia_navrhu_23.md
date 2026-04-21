Dobre. Nižšie máš **copy-paste ready minimálny set konkrétnych Python súborov** pre branch `bootstrap/minimal-e2e`.

Tento set je zámerne obmedzený na prvý vertikálny slice:

* načítanie YAML
* typed model
* validácia
* elaboration
* IR
* emit
* reporting
* CLI

Bez CPU/RAM/SoC bus vrstvy v prvej implementácii. To je podľa mňa najrýchlejšia cesta k zelenému `blink_test_01` a `blink_test_02`. Súčasný framework už má správny smer hlavne v tom, že RTL a timing majú robiť transformáciu pred renderom, a že board output má byť deterministický.   

---

## `pyproject.toml`

```toml
[project]
name = "socfw"
version = "0.1.0"
requires-python = ">=3.11"
dependencies = [
  "pydantic>=2.0",
  "pyyaml>=6.0",
  "jinja2>=3.1",
]

[project.scripts]
socfw = "socfw.cli.main:main"

[tool.pytest.ini_options]
testpaths = ["tests"]
pythonpath = ["."]
```

---

## `socfw/__init__.py`

```python
__all__ = []
```

---

## `socfw/core/diagnostics.py`

```python
from __future__ import annotations
from dataclasses import dataclass
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

---

## `socfw/core/result.py`

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

---

## `socfw/model/board.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field
from enum import Enum
from typing import Any


class PortDir(str, Enum):
    INPUT = "input"
    OUTPUT = "output"
    INOUT = "inout"


@dataclass(frozen=True)
class BoardScalarSignal:
    key: str
    top_name: str
    direction: PortDir
    pin: str
    io_standard: str | None = None
    weak_pull_up: bool = False
    meta: dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class BoardVectorSignal:
    key: str
    top_name: str
    direction: PortDir
    width: int
    pins: dict[int, str]
    io_standard: str | None = None
    weak_pull_up: bool = False
    meta: dict[str, Any] = field(default_factory=dict)

    def validate_shape(self) -> list[str]:
        errs: list[str] = []
        if self.width <= 0:
            errs.append(f"{self.key}: width must be > 0")
        if len(self.pins) != self.width:
            errs.append(f"{self.key}: width={self.width} but {len(self.pins)} pins provided")
        missing = sorted(set(range(self.width)) - set(self.pins.keys()))
        if missing:
            errs.append(f"{self.key}: missing pin indices {missing}")
        return errs


@dataclass(frozen=True)
class BoardResource:
    key: str
    kind: str
    scalars: dict[str, BoardScalarSignal] = field(default_factory=dict)
    vectors: dict[str, BoardVectorSignal] = field(default_factory=dict)
    meta: dict[str, Any] = field(default_factory=dict)

    def default_signal(self) -> BoardScalarSignal | BoardVectorSignal | None:
        if len(self.scalars) == 1 and not self.vectors:
            return next(iter(self.scalars.values()))
        if len(self.vectors) == 1 and not self.scalars:
            return next(iter(self.vectors.values()))
        return None


@dataclass(frozen=True)
class BoardConnectorRole:
    key: str
    top_name: str
    direction: PortDir
    width: int
    pins: dict[int, str]
    io_standard: str | None = None
    meta: dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class BoardConnector:
    key: str
    roles: dict[str, BoardConnectorRole] = field(default_factory=dict)


@dataclass(frozen=True)
class BoardClockDef:
    id: str
    top_name: str
    pin: str
    frequency_hz: int
    io_standard: str | None = None
    period_ns: float | None = None


@dataclass(frozen=True)
class BoardResetDef:
    id: str
    top_name: str
    pin: str
    active_low: bool
    io_standard: str | None = None
    weak_pull_up: bool = False


@dataclass(frozen=True)
class BoardModel:
    board_id: str
    vendor: str | None
    title: str | None
    fpga_family: str
    fpga_part: str
    sys_clock: BoardClockDef
    sys_reset: BoardResetDef
    onboard: dict[str, BoardResource] = field(default_factory=dict)
    connectors: dict[str, BoardConnector] = field(default_factory=dict)
    metadata: dict[str, Any] = field(default_factory=dict)

    def resolve_ref(self, ref: str) -> BoardResource | BoardConnectorRole:
        if not ref.startswith("board:"):
            raise KeyError(f"Not a board ref: {ref}")

        path = ref[len("board:"):]
        parts = path.split(".")

        if len(parts) == 2 and parts[0] == "onboard":
            key = parts[1]
            if key not in self.onboard:
                raise KeyError(f"Unknown onboard resource '{key}'")
            return self.onboard[key]

        if len(parts) == 5 and parts[0] == "connector" and parts[1] == "pmod" and parts[3] == "role":
            conn = parts[2]
            role = parts[4]
            if conn not in self.connectors:
                raise KeyError(f"Unknown connector '{conn}'")
            if role not in self.connectors[conn].roles:
                raise KeyError(f"Unknown role '{role}' on connector '{conn}'")
            return self.connectors[conn].roles[role]

        raise KeyError(f"Unsupported board ref '{ref}'")

    def validate(self) -> list[str]:
        errs: list[str] = []
        seen_top_names: set[str] = {self.sys_clock.top_name, self.sys_reset.top_name}

        for name, res in self.onboard.items():
            for sig in res.scalars.values():
                if sig.top_name in seen_top_names:
                    errs.append(f"Duplicate top_name '{sig.top_name}' in onboard.{name}")
                seen_top_names.add(sig.top_name)

            for vec in res.vectors.values():
                if vec.top_name in seen_top_names:
                    errs.append(f"Duplicate top_name '{vec.top_name}' in onboard.{name}")
                seen_top_names.add(vec.top_name)
                errs.extend(vec.validate_shape())

        for conn_name, conn in self.connectors.items():
            for role_name, role in conn.roles.items():
                if role.top_name in seen_top_names:
                    errs.append(f"Duplicate top_name '{role.top_name}' in connector.{conn_name}.role.{role_name}")
                seen_top_names.add(role.top_name)
                if len(role.pins) != role.width:
                    errs.append(
                        f"connector.{conn_name}.role.{role_name}: width={role.width} but {len(role.pins)} pins provided"
                    )

        return errs
```

---

## `socfw/model/ip.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field
from typing import Any


@dataclass(frozen=True)
class IpOrigin:
    kind: str
    tool: str | None = None
    packaging: str | None = None


@dataclass(frozen=True)
class IpArtifactBundle:
    synthesis: tuple[str, ...] = ()
    simulation: tuple[str, ...] = ()
    metadata: tuple[str, ...] = ()

    def all_files(self) -> tuple[str, ...]:
        return self.synthesis + self.simulation + self.metadata


@dataclass(frozen=True)
class IpResetSemantics:
    port: str | None = None
    active_high: bool = False
    bypass_sync: bool = False
    optional: bool = False
    asynchronous: bool = False


@dataclass(frozen=True)
class IpClockOutput:
    port: str
    kind: str
    default_domain: str | None = None
    signal_name: str | None = None


@dataclass(frozen=True)
class IpClocking:
    primary_input_port: str | None = None
    additional_input_ports: tuple[str, ...] = ()
    outputs: tuple[IpClockOutput, ...] = ()

    def find_output(self, port_name: str) -> IpClockOutput | None:
        for out in self.outputs:
            if out.port == port_name:
                return out
        return None


@dataclass(frozen=True)
class IpDescriptor:
    name: str
    module: str
    category: str
    origin: IpOrigin
    needs_bus: bool
    generate_registers: bool
    instantiate_directly: bool
    dependency_only: bool
    reset: IpResetSemantics
    clocking: IpClocking
    artifacts: IpArtifactBundle
    meta: dict[str, Any] = field(default_factory=dict)

    def validate(self) -> list[str]:
        errs: list[str] = []
        if not self.module:
            errs.append(f"{self.name}: module must not be empty")
        if self.dependency_only and self.instantiate_directly:
            errs.append(f"{self.name}: dependency_only and instantiate_directly cannot both be true")
        if self.origin.kind == "vendor_generated" and not self.artifacts.synthesis:
            errs.append(f"{self.name}: vendor_generated IP must declare synthesis artifacts")
        if self.reset.bypass_sync and self.reset.port is None:
            errs.append(f"{self.name}: bypass_sync requires reset.port")
        return errs
```

---

## `socfw/model/project.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field
from typing import Any


@dataclass(frozen=True)
class PortBinding:
    port_name: str
    target: str
    top_name: str | None = None
    width: int | None = None
    adapt: str | None = None


@dataclass(frozen=True)
class ClockBinding:
    port_name: str
    domain: str
    no_reset: bool = False


@dataclass
class ModuleInstance:
    instance: str
    type_name: str
    params: dict[str, Any] = field(default_factory=dict)
    clocks: list[ClockBinding] = field(default_factory=list)
    port_bindings: list[PortBinding] = field(default_factory=list)

    def clock_for_port(self, port_name: str) -> ClockBinding | None:
        for cb in self.clocks:
            if cb.port_name == port_name:
                return cb
        return None


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
    board_file: str | None = None
    registries_ip: list[str] = field(default_factory=list)
    feature_refs: list[str] = field(default_factory=list)
    modules: list[ModuleInstance] = field(default_factory=list)
    primary_clock_domain: str = "sys_clk"
    generated_clocks: list[GeneratedClockRequest] = field(default_factory=list)
    timing_file: str | None = None
    debug: bool = False

    def module_by_name(self, instance: str) -> ModuleInstance | None:
        for m in self.modules:
            if m.instance == instance:
                return m
        return None

    def validate(self) -> list[str]:
        errs: list[str] = []
        seen: set[str] = set()

        for mod in self.modules:
            if mod.instance in seen:
                errs.append(f"Duplicate module instance '{mod.instance}'")
            seen.add(mod.instance)

            clock_ports = [c.port_name for c in mod.clocks]
            if len(clock_ports) != len(set(clock_ports)):
                errs.append(f"{mod.instance}: duplicate clock binding port")

            bind_ports = [b.port_name for b in mod.port_bindings]
            if len(bind_ports) != len(set(bind_ports)):
                errs.append(f"{mod.instance}: duplicate port binding")

        gen_names = [g.domain for g in self.generated_clocks]
        if len(gen_names) != len(set(gen_names)):
            errs.append("Duplicate generated clock domain name")

        return errs
```

---

## `socfw/model/timing.py`

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
    comment: str = ""


@dataclass(frozen=True)
class FalsePathConstraint:
    from_port: str | None = None
    from_clock: str | None = None
    to_clock: str | None = None
    from_cell: str | None = None
    to_cell: str | None = None
    comment: str = ""


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
    false_paths: list[FalsePathConstraint] = field(default_factory=list)
    derive_uncertainty: bool = True

    def validate(self) -> list[str]:
        errs: list[str] = []
        names = [c.name for c in self.primary_clocks] + [g.name for g in self.generated_clocks]
        if len(names) != len(set(names)):
            errs.append("Duplicate timing clock names")
        for g in self.generated_clocks:
            if g.multiply_by <= 0 or g.divide_by <= 0:
                errs.append(f"{g.name}: multiply_by and divide_by must be > 0")
        return errs
```

---

## `socfw/model/system.py`

```python
from __future__ import annotations
from dataclasses import dataclass

from .board import BoardModel
from .ip import IpDescriptor
from .project import ProjectModel
from .timing import TimingModel


@dataclass
class SystemModel:
    board: BoardModel
    project: ProjectModel
    timing: TimingModel | None
    ip_catalog: dict[str, IpDescriptor]

    def validate(self) -> list[str]:
        errs: list[str] = []
        errs.extend(self.board.validate())
        errs.extend(self.project.validate())
        if self.timing:
            errs.extend(self.timing.validate())
        for ip in self.ip_catalog.values():
            errs.extend(ip.validate())
        return errs
```

---

## `socfw/config/common.py`

```python
from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml

from socfw.core.diagnostics import Diagnostic, Severity, SourceRef
from socfw.core.result import Result


def load_yaml_file(path: str | Path) -> Result[dict[str, Any]]:
    p = Path(path)

    if not p.exists():
        return Result(
            diagnostics=[
                Diagnostic(
                    code="CFG001",
                    severity=Severity.ERROR,
                    message=f"Configuration file not found: {p}",
                    subject="config",
                    refs=(SourceRef(file=str(p)),),
                )
            ]
        )

    try:
        with p.open("r", encoding="utf-8") as f:
            data = yaml.safe_load(f) or {}
    except Exception as exc:
        return Result(
            diagnostics=[
                Diagnostic(
                    code="CFG002",
                    severity=Severity.ERROR,
                    message=f"Failed to parse YAML file '{p}': {exc}",
                    subject="config",
                    refs=(SourceRef(file=str(p)),),
                )
            ]
        )

    if not isinstance(data, dict):
        return Result(
            diagnostics=[
                Diagnostic(
                    code="CFG003",
                    severity=Severity.ERROR,
                    message=f"Top-level YAML document in '{p}' must be a mapping/object",
                    subject="config",
                    refs=(SourceRef(file=str(p)),),
                )
            ]
        )

    return Result(value=data)
```

---

## `socfw/config/board_schema.py`

```python
from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field, model_validator


class BoardScalarSignalSchema(BaseModel):
    top_name: str
    direction: Literal["input", "output", "inout"]
    pin: str
    io_standard: str | None = None
    weak_pull_up: bool = False


class BoardVectorSignalSchema(BaseModel):
    top_name: str
    direction: Literal["input", "output", "inout"]
    width: int
    pins: dict[int, str]
    io_standard: str | None = None
    weak_pull_up: bool = False

    @model_validator(mode="after")
    def _validate_shape(self):
        if self.width <= 0:
            raise ValueError("width must be > 0")
        if len(self.pins) != self.width:
            raise ValueError(f"width={self.width} but pins has {len(self.pins)} entries")
        missing = sorted(set(range(self.width)) - set(self.pins.keys()))
        if missing:
            raise ValueError(f"missing pin indices: {missing}")
        return self


class BoardResourceSchema(BaseModel):
    kind: str
    top_name: str | None = None
    direction: Literal["input", "output", "inout"] | None = None
    width: int | None = None
    pins: dict[int, str] | None = None
    pin: str | None = None
    io_standard: str | None = None
    weak_pull_up: bool = False
    model: str | None = None
    comment: str | None = None
    signals: dict[str, BoardScalarSignalSchema] = Field(default_factory=dict)
    groups: dict[str, BoardVectorSignalSchema] = Field(default_factory=dict)

    @model_validator(mode="after")
    def _validate_resource(self):
        simple_scalar = (
            self.top_name is not None and self.direction is not None and self.pin is not None
            and self.width is None and self.pins is None
        )
        simple_vector = (
            self.top_name is not None and self.direction is not None and self.width is not None
            and self.pins is not None and self.pin is None
        )
        complex_bundle = bool(self.signals or self.groups)
        if not (simple_scalar or simple_vector or complex_bundle):
            raise ValueError("resource must be scalar, vector, or bundle")
        return self


class BoardConnectorRoleSchema(BaseModel):
    top_name: str
    direction: Literal["input", "output", "inout"]
    width: int
    pins: dict[int, str]
    io_standard: str | None = None


class BoardConnectorSchema(BaseModel):
    roles: dict[str, BoardConnectorRoleSchema] = Field(default_factory=dict)


class BoardClockSchema(BaseModel):
    id: str
    top_name: str
    pin: str
    io_standard: str | None = None
    frequency_hz: int
    period_ns: float | None = None


class BoardResetSchema(BaseModel):
    id: str
    top_name: str
    pin: str
    io_standard: str | None = None
    active_low: bool = True
    weak_pull_up: bool = False


class BoardMetaSchema(BaseModel):
    id: str
    vendor: str | None = None
    title: str | None = None


class FpgaSchema(BaseModel):
    family: str
    part: str


class BoardResourcesSchema(BaseModel):
    onboard: dict[str, BoardResourceSchema] = Field(default_factory=dict)
    connectors: dict[str, dict[str, BoardConnectorSchema]] = Field(default_factory=dict)


class BoardSystemSchema(BaseModel):
    clock: BoardClockSchema
    reset: BoardResetSchema


class BoardConfigSchema(BaseModel):
    version: Literal[2]
    kind: Literal["board"]
    board: BoardMetaSchema
    fpga: FpgaSchema
    system: BoardSystemSchema
    resources: BoardResourcesSchema
    toolchains: dict = Field(default_factory=dict)
```

---

## `socfw/config/ip_schema.py`

```python
from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field


class IpMetaSchema(BaseModel):
    name: str
    module: str
    category: str


class IpOriginSchema(BaseModel):
    kind: Literal["source", "vendor_generated", "generated"]
    tool: str | None = None
    packaging: str | None = None


class IpIntegrationSchema(BaseModel):
    needs_bus: bool = False
    generate_registers: bool = False
    instantiate_directly: bool = True
    dependency_only: bool = False
    no_hw_warning: bool = False


class IpResetSchema(BaseModel):
    port: str | None = None
    active_high: bool = False
    bypass_sync: bool = False
    optional: bool = False
    asynchronous: bool = False


class IpClockOutputSchema(BaseModel):
    port: str
    kind: Literal["generated_clock", "status"]
    default_domain: str | None = None
    signal_name: str | None = None


class IpClockingSchema(BaseModel):
    primary_input_port: str | None = None
    additional_input_ports: list[str] = Field(default_factory=list)
    outputs: list[IpClockOutputSchema] = Field(default_factory=list)


class IpArtifactsSchema(BaseModel):
    synthesis: list[str] = Field(default_factory=list)
    simulation: list[str] = Field(default_factory=list)
    metadata: list[str] = Field(default_factory=list)


class IpConfigSchema(BaseModel):
    version: Literal[2]
    kind: Literal["ip"]
    ip: IpMetaSchema
    origin: IpOriginSchema
    integration: IpIntegrationSchema = Field(default_factory=IpIntegrationSchema)
    reset: IpResetSchema = Field(default_factory=IpResetSchema)
    clocking: IpClockingSchema = Field(default_factory=IpClockingSchema)
    artifacts: IpArtifactsSchema = Field(default_factory=IpArtifactsSchema)
    notes: list[str] = Field(default_factory=list)
```

---

## `socfw/config/project_schema.py`

```python
from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field, model_validator


class ProjectMetaSchema(BaseModel):
    name: str
    mode: Literal["standalone", "soc"]
    board: str
    board_file: str | None = None
    output_dir: str = "build/gen"
    debug: bool = False


class RegistriesSchema(BaseModel):
    ip: list[str] = Field(default_factory=list)


class FeaturesSchema(BaseModel):
    use: list[str] = Field(default_factory=list)


class PrimaryClockSchema(BaseModel):
    domain: str
    source: str


class GeneratedClockSourceSchema(BaseModel):
    instance: str
    output: str


class GeneratedClockResetSchema(BaseModel):
    sync_from: str | None = None
    sync_stages: int | None = None
    none: bool = False


class GeneratedClockSchema(BaseModel):
    domain: str
    source: GeneratedClockSourceSchema
    frequency_hz: int | None = None
    reset: GeneratedClockResetSchema | None = None


class ClocksSchema(BaseModel):
    primary: PrimaryClockSchema
    generated: list[GeneratedClockSchema] = Field(default_factory=list)


class PortBindingSchema(BaseModel):
    target: str
    top_name: str | None = None
    width: int | None = None
    adapt: str | None = None


class ModuleBindSchema(BaseModel):
    ports: dict[str, PortBindingSchema] = Field(default_factory=dict)


class ModuleClockPortSchema(BaseModel):
    domain: str
    no_reset: bool = False


class ModuleSchema(BaseModel):
    instance: str
    type: str
    params: dict[str, Any] = Field(default_factory=dict)
    clocks: dict[str, str | ModuleClockPortSchema] = Field(default_factory=dict)
    bind: ModuleBindSchema = Field(default_factory=ModuleBindSchema)


class TimingRefSchema(BaseModel):
    file: str


class ArtifactsSchema(BaseModel):
    emit: list[str] = Field(default_factory=lambda: ["rtl", "timing", "board", "docs"])


class ProjectConfigSchema(BaseModel):
    version: Literal[2]
    kind: Literal["project"]
    project: ProjectMetaSchema
    registries: RegistriesSchema = Field(default_factory=RegistriesSchema)
    features: FeaturesSchema = Field(default_factory=FeaturesSchema)
    clocks: ClocksSchema
    modules: list[ModuleSchema] = Field(default_factory=list)
    timing: TimingRefSchema | None = None
    artifacts: ArtifactsSchema = Field(default_factory=ArtifactsSchema)

    @model_validator(mode="after")
    def _validate_unique_names(self):
        names = [m.instance for m in self.modules]
        if len(names) != len(set(names)):
            raise ValueError("duplicate module instance names")
        domains = [g.domain for g in self.clocks.generated]
        if len(domains) != len(set(domains)):
            raise ValueError("duplicate generated clock domains")
        return self
```

---

## `socfw/config/timing_schema.py`

```python
from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field


class TimingResetSchema(BaseModel):
    source: str
    active_low: bool = True
    sync_stages: int = 2


class TimingPrimaryClockSchema(BaseModel):
    name: str
    source: str
    period_ns: float
    uncertainty_ns: float | None = None
    reset: TimingResetSchema | None = None


class TimingGeneratedClockSourceSchema(BaseModel):
    instance: str
    output: str


class TimingGeneratedClockSchema(BaseModel):
    name: str
    source: TimingGeneratedClockSourceSchema
    multiply_by: int
    divide_by: int
    pin_index: int | None = None
    phase_shift_ps: int | None = None
    reset_sync_from: str | None = None
    reset_sync_stages: int | None = None


class ClockGroupSchema(BaseModel):
    type: str
    groups: list[list[str]] = Field(default_factory=list)


class IoDelayOverrideSchema(BaseModel):
    port: str
    direction: Literal["input", "output"]
    clock: str
    max_ns: float
    min_ns: float | None = None
    comment: str = ""


class IoDelaysSchema(BaseModel):
    auto: bool = True
    default_clock: str | None = None
    default_input_max_ns: float | None = None
    default_output_max_ns: float | None = None
    overrides: list[IoDelayOverrideSchema] = Field(default_factory=list)


class FalsePathSchema(BaseModel):
    from_port: str | None = None
    from_clock: str | None = None
    to_clock: str | None = None
    from_cell: str | None = None
    to_cell: str | None = None
    comment: str = ""


class TimingConfigSchema(BaseModel):
    derive_uncertainty: bool = True
    clocks: list[TimingPrimaryClockSchema] = Field(default_factory=list)
    generated_clocks: list[TimingGeneratedClockSchema] = Field(default_factory=list)
    clock_groups: list[ClockGroupSchema] = Field(default_factory=list)
    io_delays: IoDelaysSchema = Field(default_factory=IoDelaysSchema)
    false_paths: list[FalsePathSchema] = Field(default_factory=list)


class TimingDocumentSchema(BaseModel):
    version: Literal[2]
    kind: Literal["timing"]
    timing: TimingConfigSchema
```

---

## `socfw/config/board_loader.py`

```python
from __future__ import annotations

from pydantic import ValidationError

from socfw.config.board_schema import BoardConfigSchema
from socfw.config.common import load_yaml_file
from socfw.core.diagnostics import Diagnostic, Severity, SourceRef
from socfw.core.result import Result
from socfw.model.board import (
    BoardClockDef,
    BoardConnector,
    BoardConnectorRole,
    BoardModel,
    BoardResetDef,
    BoardResource,
    BoardScalarSignal,
    BoardVectorSignal,
    PortDir,
)


class BoardLoader:
    def load(self, path: str) -> Result[BoardModel]:
        raw = load_yaml_file(path)
        if not raw.ok:
            return Result(diagnostics=raw.diagnostics)

        try:
            doc = BoardConfigSchema.model_validate(raw.value)
        except ValidationError as exc:
            return Result(
                diagnostics=[Diagnostic(
                    code="BRD100",
                    severity=Severity.ERROR,
                    message=f"Invalid board YAML: {exc}",
                    subject="board",
                    refs=(SourceRef(file=path),),
                )]
            )

        onboard: dict[str, BoardResource] = {}
        for key, res in doc.resources.onboard.items():
            if res.signals or res.groups:
                scalars = {
                    sig_key: BoardScalarSignal(
                        key=sig_key,
                        top_name=sig.top_name,
                        direction=PortDir(sig.direction),
                        pin=sig.pin,
                        io_standard=sig.io_standard,
                        weak_pull_up=sig.weak_pull_up,
                    )
                    for sig_key, sig in res.signals.items()
                }
                vectors = {
                    grp_key: BoardVectorSignal(
                        key=grp_key,
                        top_name=grp.top_name,
                        direction=PortDir(grp.direction),
                        width=grp.width,
                        pins=grp.pins,
                        io_standard=grp.io_standard,
                        weak_pull_up=grp.weak_pull_up,
                    )
                    for grp_key, grp in res.groups.items()
                }
            else:
                scalars = {}
                vectors = {}
                if res.pin is not None:
                    scalars["default"] = BoardScalarSignal(
                        key="default",
                        top_name=res.top_name or key.upper(),
                        direction=PortDir(res.direction or "output"),
                        pin=res.pin,
                        io_standard=res.io_standard,
                        weak_pull_up=res.weak_pull_up,
                    )
                elif res.pins is not None and res.width is not None:
                    vectors["default"] = BoardVectorSignal(
                        key="default",
                        top_name=res.top_name or key.upper(),
                        direction=PortDir(res.direction or "output"),
                        width=res.width,
                        pins=res.pins,
                        io_standard=res.io_standard,
                        weak_pull_up=res.weak_pull_up,
                    )

            onboard[key] = BoardResource(
                key=key,
                kind=res.kind,
                scalars=scalars,
                vectors=vectors,
                meta={"model": res.model, "comment": res.comment},
            )

        connectors: dict[str, BoardConnector] = {}
        pmod = doc.resources.connectors.get("pmod", {})
        for conn_key, conn_value in pmod.items():
            roles = {
                role_key: BoardConnectorRole(
                    key=role_key,
                    top_name=role.top_name,
                    direction=PortDir(role.direction),
                    width=role.width,
                    pins=role.pins,
                    io_standard=role.io_standard,
                )
                for role_key, role in conn_value.roles.items()
            }
            connectors[conn_key] = BoardConnector(key=conn_key, roles=roles)

        model = BoardModel(
            board_id=doc.board.id,
            vendor=doc.board.vendor,
            title=doc.board.title,
            fpga_family=doc.fpga.family,
            fpga_part=doc.fpga.part,
            sys_clock=BoardClockDef(
                id=doc.system.clock.id,
                top_name=doc.system.clock.top_name,
                pin=doc.system.clock.pin,
                frequency_hz=doc.system.clock.frequency_hz,
                io_standard=doc.system.clock.io_standard,
                period_ns=doc.system.clock.period_ns,
            ),
            sys_reset=BoardResetDef(
                id=doc.system.reset.id,
                top_name=doc.system.reset.top_name,
                pin=doc.system.reset.pin,
                active_low=doc.system.reset.active_low,
                io_standard=doc.system.reset.io_standard,
                weak_pull_up=doc.system.reset.weak_pull_up,
            ),
            onboard=onboard,
            connectors=connectors,
            metadata={"toolchains": doc.toolchains},
        )

        errs = model.validate()
        if errs:
            return Result(diagnostics=[
                Diagnostic(
                    code="BRD101",
                    severity=Severity.ERROR,
                    message=msg,
                    subject="board",
                    refs=(SourceRef(file=path),),
                )
                for msg in errs
            ])

        return Result(value=model)
```

---

## `socfw/config/ip_loader.py`

```python
from __future__ import annotations

from pathlib import Path

from pydantic import ValidationError

from socfw.config.common import load_yaml_file
from socfw.config.ip_schema import IpConfigSchema
from socfw.core.diagnostics import Diagnostic, Severity, SourceRef
from socfw.core.result import Result
from socfw.model.ip import (
    IpArtifactBundle,
    IpClockOutput,
    IpClocking,
    IpDescriptor,
    IpOrigin,
    IpResetSemantics,
)


class IpLoader:
    def load_file(self, path: str) -> Result[IpDescriptor]:
        raw = load_yaml_file(path)
        if not raw.ok:
            return Result(diagnostics=raw.diagnostics)

        try:
            doc = IpConfigSchema.model_validate(raw.value)
        except ValidationError as exc:
            return Result(diagnostics=[
                Diagnostic(
                    code="IP100",
                    severity=Severity.ERROR,
                    message=f"Invalid IP YAML: {exc}",
                    subject="ip",
                    refs=(SourceRef(file=path),),
                )
            ])

        ip = IpDescriptor(
            name=doc.ip.name,
            module=doc.ip.module,
            category=doc.ip.category,
            origin=IpOrigin(
                kind=doc.origin.kind,
                tool=doc.origin.tool,
                packaging=doc.origin.packaging,
            ),
            needs_bus=doc.integration.needs_bus,
            generate_registers=doc.integration.generate_registers,
            instantiate_directly=doc.integration.instantiate_directly,
            dependency_only=doc.integration.dependency_only,
            reset=IpResetSemantics(
                port=doc.reset.port,
                active_high=doc.reset.active_high,
                bypass_sync=doc.reset.bypass_sync,
                optional=doc.reset.optional,
                asynchronous=doc.reset.asynchronous,
            ),
            clocking=IpClocking(
                primary_input_port=doc.clocking.primary_input_port,
                additional_input_ports=tuple(doc.clocking.additional_input_ports),
                outputs=tuple(
                    IpClockOutput(
                        port=o.port,
                        kind=o.kind,
                        default_domain=o.default_domain,
                        signal_name=o.signal_name,
                    )
                    for o in doc.clocking.outputs
                ),
            ),
            artifacts=IpArtifactBundle(
                synthesis=tuple(doc.artifacts.synthesis),
                simulation=tuple(doc.artifacts.simulation),
                metadata=tuple(doc.artifacts.metadata),
            ),
            meta={"notes": doc.notes},
        )

        errs = ip.validate()
        if errs:
            return Result(diagnostics=[
                Diagnostic(
                    code="IP101",
                    severity=Severity.ERROR,
                    message=msg,
                    subject="ip",
                    refs=(SourceRef(file=path),),
                )
                for msg in errs
            ])

        return Result(value=ip)

    def load_catalog(self, search_dirs: list[str]) -> Result[dict[str, IpDescriptor]]:
        catalog: dict[str, IpDescriptor] = {}
        diags: list[Diagnostic] = []

        for root in search_dirs:
            p = Path(root)
            if not p.exists():
                diags.append(Diagnostic(
                    code="IP102",
                    severity=Severity.WARNING,
                    message=f"IP registry path does not exist: {root}",
                    subject="ip.registry",
                    refs=(SourceRef(file=root),),
                ))
                continue

            for fp in sorted(p.rglob("*.ip.yaml")):
                res = self.load_file(str(fp))
                diags.extend(res.diagnostics)
                if res.ok and res.value is not None:
                    ip = res.value
                    if ip.name in catalog:
                        diags.append(Diagnostic(
                            code="IP103",
                            severity=Severity.ERROR,
                            message=f"Duplicate IP descriptor name '{ip.name}'",
                            subject="ip.registry",
                            refs=(SourceRef(file=str(fp)),),
                        ))
                    else:
                        catalog[ip.name] = ip

        return Result(value=catalog, diagnostics=diags)
```

---

## `socfw/config/project_loader.py`

```python
from __future__ import annotations

from pydantic import ValidationError

from socfw.config.common import load_yaml_file
from socfw.config.project_schema import ProjectConfigSchema
from socfw.core.diagnostics import Diagnostic, Severity, SourceRef
from socfw.core.result import Result
from socfw.model.project import (
    ClockBinding,
    GeneratedClockRequest,
    ModuleInstance,
    PortBinding,
    ProjectModel,
)


class ProjectLoader:
    def load(self, path: str) -> Result[ProjectModel]:
        raw = load_yaml_file(path)
        if not raw.ok:
            return Result(diagnostics=raw.diagnostics)

        try:
            doc = ProjectConfigSchema.model_validate(raw.value)
        except ValidationError as exc:
            return Result(diagnostics=[
                Diagnostic(
                    code="PRJ100",
                    severity=Severity.ERROR,
                    message=f"Invalid project YAML: {exc}",
                    subject="project",
                    refs=(SourceRef(file=path),),
                )
            ])

        modules: list[ModuleInstance] = []
        for m in doc.modules:
            clocks: list[ClockBinding] = []
            for port_name, value in m.clocks.items():
                if isinstance(value, str):
                    clocks.append(ClockBinding(port_name=port_name, domain=value, no_reset=False))
                else:
                    clocks.append(ClockBinding(port_name=port_name, domain=value.domain, no_reset=value.no_reset))

            port_bindings = [
                PortBinding(
                    port_name=port_name,
                    target=b.target,
                    top_name=b.top_name,
                    width=b.width,
                    adapt=b.adapt,
                )
                for port_name, b in m.bind.ports.items()
            ]

            modules.append(ModuleInstance(
                instance=m.instance,
                type_name=m.type,
                params=m.params,
                clocks=clocks,
                port_bindings=port_bindings,
            ))

        gen_clocks = [
            GeneratedClockRequest(
                domain=g.domain,
                source_instance=g.source.instance,
                source_output=g.source.output,
                frequency_hz=g.frequency_hz,
                sync_from=(g.reset.sync_from if g.reset and not g.reset.none else None),
                sync_stages=(g.reset.sync_stages if g.reset and not g.reset.none else None),
                no_reset=(g.reset.none if g.reset else False),
            )
            for g in doc.clocks.generated
        ]

        model = ProjectModel(
            name=doc.project.name,
            mode=doc.project.mode,
            board_ref=doc.project.board,
            board_file=doc.project.board_file,
            registries_ip=doc.registries.ip,
            feature_refs=doc.features.use,
            modules=modules,
            primary_clock_domain=doc.clocks.primary.domain,
            generated_clocks=gen_clocks,
            timing_file=(doc.timing.file if doc.timing else None),
            debug=doc.project.debug,
        )

        errs = model.validate()
        if errs:
            return Result(diagnostics=[
                Diagnostic(
                    code="PRJ101",
                    severity=Severity.ERROR,
                    message=msg,
                    subject="project",
                    refs=(SourceRef(file=path),),
                )
                for msg in errs
            ])

        return Result(value=model)
```

---

## `socfw/config/timing_loader.py`

```python
from __future__ import annotations

from pydantic import ValidationError

from socfw.config.common import load_yaml_file
from socfw.config.timing_schema import TimingDocumentSchema
from socfw.core.diagnostics import Diagnostic, Severity, SourceRef
from socfw.core.result import Result
from socfw.model.timing import (
    ClockGroupConstraint,
    FalsePathConstraint,
    IoDelayOverride,
    TimingGeneratedClock,
    TimingModel,
    TimingPrimaryClock,
)


class TimingLoader:
    def load(self, path: str) -> Result[TimingModel]:
        raw = load_yaml_file(path)
        if not raw.ok:
            return Result(diagnostics=raw.diagnostics)

        try:
            doc = TimingDocumentSchema.model_validate(raw.value)
        except ValidationError as exc:
            return Result(diagnostics=[
                Diagnostic(
                    code="TIM100",
                    severity=Severity.ERROR,
                    message=f"Invalid timing YAML: {exc}",
                    subject="timing",
                    refs=(SourceRef(file=path),),
                )
            ])

        timing = TimingModel(
            primary_clocks=[
                TimingPrimaryClock(
                    name=c.name,
                    source_port=c.source,
                    period_ns=c.period_ns,
                    uncertainty_ns=c.uncertainty_ns,
                    reset_port=(c.reset.source if c.reset else None),
                    reset_active_low=(c.reset.active_low if c.reset else True),
                    reset_sync_stages=(c.reset.sync_stages if c.reset else 2),
                )
                for c in doc.timing.clocks
            ],
            generated_clocks=[
                TimingGeneratedClock(
                    name=g.name,
                    source_instance=g.source.instance,
                    source_clock=g.source.output,
                    pin_index=g.pin_index,
                    multiply_by=g.multiply_by,
                    divide_by=g.divide_by,
                    phase_shift_ps=g.phase_shift_ps,
                    sync_from=g.reset_sync_from,
                    sync_stages=g.reset_sync_stages,
                )
                for g in doc.timing.generated_clocks
            ],
            clock_groups=[ClockGroupConstraint(group_type=g.type, groups=g.groups) for g in doc.timing.clock_groups],
            io_auto=doc.timing.io_delays.auto,
            io_default_clock=doc.timing.io_delays.default_clock,
            io_default_input_max_ns=doc.timing.io_delays.default_input_max_ns,
            io_default_output_max_ns=doc.timing.io_delays.default_output_max_ns,
            io_overrides=[
                IoDelayOverride(
                    port=o.port,
                    direction=o.direction,
                    clock=o.clock,
                    max_ns=o.max_ns,
                    min_ns=o.min_ns,
                    comment=o.comment,
                )
                for o in doc.timing.io_delays.overrides
            ],
            false_paths=[
                FalsePathConstraint(
                    from_port=f.from_port,
                    from_clock=f.from_clock,
                    to_clock=f.to_clock,
                    from_cell=f.from_cell,
                    to_cell=f.to_cell,
                    comment=f.comment,
                )
                for f in doc.timing.false_paths
            ],
            derive_uncertainty=doc.timing.derive_uncertainty,
        )

        errs = timing.validate()
        if errs:
            return Result(diagnostics=[
                Diagnostic(
                    code="TIM101",
                    severity=Severity.ERROR,
                    message=msg,
                    subject="timing",
                    refs=(SourceRef(file=path),),
                )
                for msg in errs
            ])

        return Result(value=timing)
```

---

## `socfw/config/system_loader.py`

```python
from __future__ import annotations

from pathlib import Path

from socfw.config.board_loader import BoardLoader
from socfw.config.ip_loader import IpLoader
from socfw.config.project_loader import ProjectLoader
from socfw.config.timing_loader import TimingLoader
from socfw.core.diagnostics import Diagnostic, Severity, SourceRef
from socfw.core.result import Result
from socfw.model.system import SystemModel


class SystemLoader:
    def __init__(self) -> None:
        self.board_loader = BoardLoader()
        self.project_loader = ProjectLoader()
        self.timing_loader = TimingLoader()
        self.ip_loader = IpLoader()

    def load(self, project_file: str) -> Result[SystemModel]:
        diags: list[Diagnostic] = []

        prj_res = self.project_loader.load(project_file)
        diags.extend(prj_res.diagnostics)
        if not prj_res.ok or prj_res.value is None:
            return Result(diagnostics=diags)

        project = prj_res.value

        if not project.board_file:
            return Result(diagnostics=diags + [
                Diagnostic(
                    code="SYS100",
                    severity=Severity.ERROR,
                    message="project.board_file is required",
                    subject="project.board_file",
                    refs=(SourceRef(file=project_file),),
                )
            ])

        board_res = self.board_loader.load(project.board_file)
        diags.extend(board_res.diagnostics)
        if not board_res.ok or board_res.value is None:
            return Result(diagnostics=diags)

        catalog_res = self.ip_loader.load_catalog(project.registries_ip)
        diags.extend(catalog_res.diagnostics)
        if not catalog_res.ok or catalog_res.value is None:
            return Result(diagnostics=diags)

        timing = None
        if project.timing_file:
            timing_path = Path(project_file).parent / project.timing_file
            tim_res = self.timing_loader.load(str(timing_path))
            diags.extend(tim_res.diagnostics)
            if not tim_res.ok:
                return Result(diagnostics=diags)
            timing = tim_res.value

        system = SystemModel(
            board=board_res.value,
            project=project,
            timing=timing,
            ip_catalog=catalog_res.value,
        )
        return Result(value=system, diagnostics=diags)
```

---

## `socfw/validate/rules/base.py`

```python
from __future__ import annotations
from abc import ABC, abstractmethod

from socfw.core.diagnostics import Diagnostic
from socfw.model.system import SystemModel


class ValidationRule(ABC):
    @abstractmethod
    def validate(self, system: SystemModel) -> list[Diagnostic]:
        raise NotImplementedError
```

---

## `socfw/validate/rules/board_rules.py`

```python
from __future__ import annotations

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.model.system import SystemModel
from .base import ValidationRule


class UnknownBoardFeatureRule(ValidationRule):
    def validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []
        for ref in system.project.feature_refs:
            try:
                system.board.resolve_ref(ref)
            except KeyError as e:
                diags.append(Diagnostic(
                    code="BRD001",
                    severity=Severity.ERROR,
                    message=str(e),
                    subject="project.features.use",
                ))
        return diags


class UnknownBoardBindingTargetRule(ValidationRule):
    def validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []
        for mod in system.project.modules:
            for binding in mod.port_bindings:
                if binding.target.startswith("board:"):
                    try:
                        system.board.resolve_ref(binding.target)
                    except KeyError as e:
                        diags.append(Diagnostic(
                            code="BRD002",
                            severity=Severity.ERROR,
                            message=f"Instance '{mod.instance}' port '{binding.port_name}': {e}",
                            subject="project.modules.bind.ports",
                        ))
        return diags
```

---

## `socfw/validate/rules/project_rules.py`

```python
from __future__ import annotations

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.model.system import SystemModel
from .base import ValidationRule


class DuplicateModuleInstanceRule(ValidationRule):
    def validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []
        seen: set[str] = set()

        for mod in system.project.modules:
            if mod.instance in seen:
                diags.append(Diagnostic(
                    code="PRJ001",
                    severity=Severity.ERROR,
                    message=f"Duplicate module instance '{mod.instance}'",
                    subject="project.modules",
                ))
            seen.add(mod.instance)

        return diags


class UnknownIpTypeRule(ValidationRule):
    def validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []
        for mod in system.project.modules:
            if mod.type_name not in system.ip_catalog:
                diags.append(Diagnostic(
                    code="PRJ002",
                    severity=Severity.ERROR,
                    message=f"Unknown IP type '{mod.type_name}' for instance '{mod.instance}'",
                    subject="project.modules",
                ))
        return diags


class UnknownGeneratedClockSourceRule(ValidationRule):
    def validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []

        for req in system.project.generated_clocks:
            inst = system.project.module_by_name(req.source_instance)
            if inst is None:
                diags.append(Diagnostic(
                    code="CLK001",
                    severity=Severity.ERROR,
                    message=f"Generated clock '{req.domain}' references unknown instance '{req.source_instance}'",
                    subject="project.clocks.generated",
                ))
                continue

            ip = system.ip_catalog.get(inst.type_name)
            if ip is None:
                continue

            out = ip.clocking.find_output(req.source_output)
            if out is None:
                diags.append(Diagnostic(
                    code="CLK002",
                    severity=Severity.ERROR,
                    message=f"Generated clock '{req.domain}' references unknown output '{req.source_output}' on IP '{inst.type_name}'",
                    subject="project.clocks.generated",
                ))
                continue

            if out.kind != "generated_clock":
                diags.append(Diagnostic(
                    code="CLK003",
                    severity=Severity.ERROR,
                    message=f"Output '{req.source_output}' on IP '{inst.type_name}' is '{out.kind}', not a generated_clock",
                    subject="project.clocks.generated",
                ))

        return diags
```

---

## `socfw/validate/rules/asset_rules.py`

```python
from __future__ import annotations
from pathlib import Path

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.model.system import SystemModel
from .base import ValidationRule


class VendorIpArtifactExistsRule(ValidationRule):
    def validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []
        for ip in system.ip_catalog.values():
            if ip.origin.kind != "vendor_generated":
                continue
            for path in ip.artifacts.synthesis:
                if not Path(path).exists():
                    diags.append(Diagnostic(
                        code="AST001",
                        severity=Severity.WARNING,
                        message=f"Vendor IP '{ip.name}' synthesis artifact not found: {path}",
                        subject="ip.artifacts.synthesis",
                    ))
        return diags
```

---

## `socfw/elaborate/board_bindings.py`

```python
from __future__ import annotations
from dataclasses import dataclass

from socfw.model.board import BoardConnectorRole, BoardResource
from socfw.model.system import SystemModel


@dataclass(frozen=True)
class ResolvedExternalPort:
    top_name: str
    direction: str
    width: int
    io_standard: str | None = None
    pins: dict[int, str] | None = None
    pin: str | None = None
    weak_pull_up: bool = False


@dataclass(frozen=True)
class ResolvedPortBinding:
    instance: str
    port_name: str
    target_ref: str
    resolved: tuple[ResolvedExternalPort, ...]
    adapt: str | None = None


class BoardBindingResolver:
    def resolve(self, system: SystemModel) -> list[ResolvedPortBinding]:
        result: list[ResolvedPortBinding] = []

        for mod in system.project.modules:
            for binding in mod.port_bindings:
                if not binding.target.startswith("board:"):
                    continue

                target = system.board.resolve_ref(binding.target)

                if isinstance(target, BoardConnectorRole):
                    resolved = (
                        ResolvedExternalPort(
                            top_name=binding.top_name or target.top_name,
                            direction=target.direction.value,
                            width=binding.width or target.width,
                            io_standard=target.io_standard,
                            pins=target.pins,
                        ),
                    )
                elif isinstance(target, BoardResource):
                    sig = target.default_signal()
                    if sig is not None:
                        if hasattr(sig, "pins"):
                            resolved = (
                                ResolvedExternalPort(
                                    top_name=binding.top_name or sig.top_name,
                                    direction=sig.direction.value,
                                    width=binding.width or sig.width,
                                    io_standard=sig.io_standard,
                                    pins=sig.pins,
                                    weak_pull_up=getattr(sig, "weak_pull_up", False),
                                ),
                            )
                        else:
                            resolved = (
                                ResolvedExternalPort(
                                    top_name=binding.top_name or sig.top_name,
                                    direction=sig.direction.value,
                                    width=1,
                                    io_standard=sig.io_standard,
                                    pin=sig.pin,
                                    weak_pull_up=sig.weak_pull_up,
                                ),
                            )
                    else:
                        parts: list[ResolvedExternalPort] = []
                        for sig in target.scalars.values():
                            parts.append(ResolvedExternalPort(
                                top_name=sig.top_name,
                                direction=sig.direction.value,
                                width=1,
                                io_standard=sig.io_standard,
                                pin=sig.pin,
                                weak_pull_up=sig.weak_pull_up,
                            ))
                        for vec in target.vectors.values():
                            parts.append(ResolvedExternalPort(
                                top_name=vec.top_name,
                                direction=vec.direction.value,
                                width=vec.width,
                                io_standard=vec.io_standard,
                                pins=vec.pins,
                                weak_pull_up=vec.weak_pull_up,
                            ))
                        resolved = tuple(parts)
                else:
                    raise TypeError(f"Unsupported board target type: {type(target)}")

                result.append(ResolvedPortBinding(
                    instance=mod.instance,
                    port_name=binding.port_name,
                    target_ref=binding.target,
                    resolved=resolved,
                    adapt=binding.adapt,
                ))

        return result
```

---

## `socfw/elaborate/clocks.py`

```python
from __future__ import annotations
from dataclasses import dataclass

from socfw.model.system import SystemModel


@dataclass(frozen=True)
class ResolvedClockDomain:
    name: str
    frequency_hz: int | None
    source_kind: str
    source_ref: str
    reset_policy: str
    sync_from: str | None = None
    sync_stages: int | None = None


class ClockResolver:
    def resolve(self, system: SystemModel) -> list[ResolvedClockDomain]:
        domains: list[ResolvedClockDomain] = []

        domains.append(ResolvedClockDomain(
            name=system.project.primary_clock_domain,
            frequency_hz=system.board.sys_clock.frequency_hz,
            source_kind="board",
            source_ref=system.board.sys_clock.top_name,
            reset_policy="synced",
            sync_stages=2,
        ))

        for req in system.project.generated_clocks:
            mod = system.project.module_by_name(req.source_instance)
            if mod is None:
                continue

            ip = system.ip_catalog.get(mod.type_name)
            if ip is None:
                continue

            out = ip.clocking.find_output(req.source_output)
            if out is None:
                continue

            if req.no_reset:
                reset_policy = "none"
            elif ip.reset.bypass_sync:
                reset_policy = "synced" if req.sync_from else "none"
            else:
                reset_policy = "synced" if req.sync_from else "none"

            domains.append(ResolvedClockDomain(
                name=req.domain,
                frequency_hz=req.frequency_hz,
                source_kind="generated",
                source_ref=f"{req.source_instance}.{req.source_output}",
                reset_policy=reset_policy,
                sync_from=req.sync_from,
                sync_stages=req.sync_stages,
            ))

        return domains
```

---

## `socfw/elaborate/design.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field

from .board_bindings import ResolvedPortBinding
from .clocks import ResolvedClockDomain


@dataclass
class ElaboratedDesign:
    system: object
    port_bindings: list[ResolvedPortBinding] = field(default_factory=list)
    clock_domains: list[ResolvedClockDomain] = field(default_factory=list)
    dependency_assets: list[str] = field(default_factory=list)
```

---

## `socfw/elaborate/planner.py`

```python
from __future__ import annotations

from socfw.model.system import SystemModel
from .board_bindings import BoardBindingResolver
from .clocks import ClockResolver
from .design import ElaboratedDesign


class Elaborator:
    def __init__(self) -> None:
        self.board_bindings = BoardBindingResolver()
        self.clocks = ClockResolver()

    def elaborate(self, system: SystemModel) -> ElaboratedDesign:
        design = ElaboratedDesign(system=system)
        design.port_bindings = self.board_bindings.resolve(system)
        design.clock_domains = self.clocks.resolve(system)

        used_types = {m.type_name for m in system.project.modules}
        for t in used_types:
            ip = system.ip_catalog.get(t)
            if ip is None:
                continue
            design.dependency_assets.extend(ip.artifacts.synthesis)

        return design
```

---

## `socfw/ir/board.py`

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

    def add_scalar(self, *, top_name: str, pin: str, io_standard: str | None = None, weak_pull_up: bool = False) -> None:
        self.assignments.append(BoardPinAssignment(
            top_name=top_name,
            index=None,
            pin=pin,
            io_standard=io_standard,
            weak_pull_up=weak_pull_up,
        ))

    def add_vector(self, *, top_name: str, pins: dict[int, str], io_standard: str | None = None, weak_pull_up: bool = False) -> None:
        for idx, pin in sorted(pins.items()):
            self.assignments.append(BoardPinAssignment(
                top_name=top_name,
                index=idx,
                pin=pin,
                io_standard=io_standard,
                weak_pull_up=weak_pull_up,
            ))
```

---

## `socfw/ir/timing.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class ClockConstraint:
    name: str
    source_port: str
    period_ns: float
    uncertainty_ns: float | None = None


@dataclass(frozen=True)
class GeneratedClockConstraint:
    name: str
    source_instance: str
    source_output: str
    source_clock: str
    multiply_by: int
    divide_by: int
    pin_index: int | None = None
    phase_shift_ps: int | None = None


@dataclass(frozen=True)
class FalsePathConstraintIR:
    from_port: str | None = None
    from_clock: str | None = None
    to_clock: str | None = None
    from_cell: str | None = None
    to_cell: str | None = None
    comment: str = ""


@dataclass(frozen=True)
class IoDelayConstraintIR:
    port: str
    direction: str
    clock: str
    max_ns: float
    min_ns: float | None = None
    comment: str = ""


@dataclass
class TimingIR:
    clocks: list[ClockConstraint] = field(default_factory=list)
    generated_clocks: list[GeneratedClockConstraint] = field(default_factory=list)
    clock_groups: list[dict] = field(default_factory=list)
    false_paths: list[FalsePathConstraintIR] = field(default_factory=list)
    io_delays: list[IoDelayConstraintIR] = field(default_factory=list)
    derive_uncertainty: bool = True
```

---

## `socfw/ir/rtl.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field


BOARD_CLOCK = "SYS_CLK"
BOARD_RESET = "RESET_N"


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
    comment: str = ""


@dataclass(frozen=True)
class RtlResetSync:
    name: str
    stages: int
    clk_signal: str
    rst_out: str


@dataclass
class RtlModuleIR:
    name: str
    ports: list[RtlPort] = field(default_factory=list)
    wires: list[RtlWire] = field(default_factory=list)
    assigns: list[RtlAssign] = field(default_factory=list)
    instances: list[RtlInstance] = field(default_factory=list)
    reset_syncs: list[RtlResetSync] = field(default_factory=list)
    extra_sources: list[str] = field(default_factory=list)

    def add_port_once(self, port: RtlPort) -> None:
        if all(p.name != port.name for p in self.ports):
            self.ports.append(port)

    def add_wire_once(self, wire: RtlWire) -> None:
        if all(w.name != wire.name for w in self.wires):
            self.wires.append(wire)
```

---

## `socfw/builders/board_ir_builder.py`

```python
from __future__ import annotations

from socfw.elaborate.design import ElaboratedDesign
from socfw.ir.board import BoardIR


class BoardIRBuilder:
    def build(self, design: ElaboratedDesign) -> BoardIR:
        board = design.system.board
        ir = BoardIR(
            family=board.fpga_family,
            device=board.fpga_part,
        )

        ir.add_scalar(
            top_name=board.sys_clock.top_name,
            pin=board.sys_clock.pin,
            io_standard=board.sys_clock.io_standard,
        )
        ir.add_scalar(
            top_name=board.sys_reset.top_name,
            pin=board.sys_reset.pin,
            io_standard=board.sys_reset.io_standard,
            weak_pull_up=board.sys_reset.weak_pull_up,
        )

        seen_scalars: set[tuple[str, str]] = set()
        seen_vectors: set[tuple[str, tuple[tuple[int, str], ...]]] = set()

        for binding in design.port_bindings:
            for ext in binding.resolved:
                if ext.pin is not None:
                    key = (ext.top_name, ext.pin)
                    if key in seen_scalars:
                        continue
                    ir.add_scalar(
                        top_name=ext.top_name,
                        pin=ext.pin,
                        io_standard=ext.io_standard,
                        weak_pull_up=ext.weak_pull_up,
                    )
                    seen_scalars.add(key)
                elif ext.pins is not None:
                    norm = tuple(sorted(ext.pins.items()))
                    key = (ext.top_name, norm)
                    if key in seen_vectors:
                        continue
                    ir.add_vector(
                        top_name=ext.top_name,
                        pins=ext.pins,
                        io_standard=ext.io_standard,
                        weak_pull_up=ext.weak_pull_up,
                    )
                    seen_vectors.add(key)

        return ir
```

---

## `socfw/builders/timing_ir_builder.py`

```python
from __future__ import annotations

from socfw.elaborate.design import ElaboratedDesign
from socfw.ir.timing import (
    ClockConstraint,
    FalsePathConstraintIR,
    GeneratedClockConstraint,
    IoDelayConstraintIR,
    TimingIR,
)


class TimingIRBuilder:
    def build(self, design: ElaboratedDesign) -> TimingIR:
        system = design.system
        timing = system.timing

        ir = TimingIR()
        if timing is None:
            return ir

        ir.derive_uncertainty = timing.derive_uncertainty

        for clk in timing.primary_clocks:
            ir.clocks.append(ClockConstraint(
                name=clk.name,
                source_port=clk.source_port,
                period_ns=clk.period_ns,
                uncertainty_ns=clk.uncertainty_ns,
            ))
            if clk.reset_port:
                ir.false_paths.append(FalsePathConstraintIR(
                    from_port=clk.reset_port,
                    comment=f"Async reset for domain {clk.name}",
                ))

        for gclk in timing.generated_clocks:
            ir.generated_clocks.append(GeneratedClockConstraint(
                name=gclk.name,
                source_instance=gclk.source_instance,
                source_output=gclk.source_clock,
                source_clock=gclk.source_clock,
                multiply_by=gclk.multiply_by,
                divide_by=gclk.divide_by,
                pin_index=gclk.pin_index,
                phase_shift_ps=gclk.phase_shift_ps,
            ))
            if gclk.sync_from:
                ir.false_paths.append(FalsePathConstraintIR(
                    from_clock=gclk.sync_from,
                    to_clock=gclk.name,
                    comment=f"CDC reset sync: {gclk.sync_from} -> {gclk.name} ({gclk.sync_stages or 2}-stage FF)",
                ))

        for grp in timing.clock_groups:
            ir.clock_groups.append({"type": grp.group_type, "groups": grp.groups})

        for fp in timing.false_paths:
            ir.false_paths.append(FalsePathConstraintIR(
                from_port=fp.from_port,
                from_clock=fp.from_clock,
                to_clock=fp.to_clock,
                from_cell=fp.from_cell,
                to_cell=fp.to_cell,
                comment=fp.comment,
            ))

        if timing.io_auto:
            override_ports = {ov.port for ov in timing.io_overrides}
            default_clock = timing.io_default_clock

            for binding in design.port_bindings:
                for ext in binding.resolved:
                    if ext.top_name in override_ports:
                        continue
                    direction = "input" if ext.direction == "input" else "output"
                    max_ns = timing.io_default_input_max_ns if direction == "input" else timing.io_default_output_max_ns
                    if default_clock and max_ns is not None:
                        ir.io_delays.append(IoDelayConstraintIR(
                            port=ext.top_name,
                            direction=direction,
                            clock=default_clock,
                            max_ns=max_ns,
                            comment=f"{binding.instance}.{binding.port_name}",
                        ))

        for ov in timing.io_overrides:
            ir.io_delays.append(IoDelayConstraintIR(
                port=ov.port,
                direction=ov.direction,
                clock=ov.clock,
                max_ns=ov.max_ns,
                min_ns=ov.min_ns,
                comment=ov.comment,
            ))

        return ir
```

---

## `socfw/builders/rtl_ir_builder.py`

```python
from __future__ import annotations

from socfw.elaborate.design import ElaboratedDesign
from socfw.ir.rtl import (
    BOARD_CLOCK,
    BOARD_RESET,
    RtlAssign,
    RtlConn,
    RtlInstance,
    RtlModuleIR,
    RtlPort,
    RtlResetSync,
    RtlWire,
)


class RtlIRBuilder:
    def build(self, design: ElaboratedDesign) -> RtlModuleIR:
        system = design.system
        rtl = RtlModuleIR(name="soc_top")

        rtl.add_port_once(RtlPort(name=BOARD_CLOCK, direction="input", width=1))
        rtl.add_port_once(RtlPort(name=BOARD_RESET, direction="input", width=1))

        for binding in design.port_bindings:
            for ext in binding.resolved:
                rtl.add_port_once(RtlPort(
                    name=ext.top_name,
                    direction=ext.direction,
                    width=ext.width,
                ))

        for dom in design.clock_domains:
            if dom.reset_policy == "synced" and dom.name != system.project.primary_clock_domain:
                rst_out = f"rst_n_{dom.name}"
                rtl.add_wire_once(RtlWire(name=dom.name, width=1, comment="clock domain"))
                rtl.add_wire_once(RtlWire(name=rst_out, width=1, comment="reset sync output"))
                rtl.reset_syncs.append(RtlResetSync(
                    name=f"u_rst_sync_{dom.name}",
                    stages=dom.sync_stages or 2,
                    clk_signal=dom.name,
                    rst_out=rst_out,
                ))
            elif dom.source_kind == "generated":
                rtl.add_wire_once(RtlWire(name=dom.name, width=1, comment="generated clock"))

        for mod in system.project.modules:
            ip = system.ip_catalog.get(mod.type_name)
            if ip is None:
                continue

            conns: list[RtlConn] = []

            for cb in mod.clocks:
                signal = cb.domain
                if cb.domain == system.project.primary_clock_domain:
                    signal = BOARD_CLOCK
                conns.append(RtlConn(port=cb.port_name, signal=signal))

                if not cb.no_reset and ip.reset.port:
                    rst_sig = BOARD_RESET if cb.domain == system.project.primary_clock_domain else f"rst_n_{cb.domain}"
                    if ip.reset.active_high:
                        rst_sig = f"~{rst_sig}"
                    conns.append(RtlConn(port=ip.reset.port, signal=rst_sig))

            for binding in mod.port_bindings:
                resolved = next(
                    (b for b in design.port_bindings if b.instance == mod.instance and b.port_name == binding.port_name),
                    None,
                )
                if resolved is None:
                    continue

                if len(resolved.resolved) == 1:
                    ext = resolved.resolved[0]
                    needs_adapter = binding.width is not None and binding.width != ext.width
                    if not needs_adapter:
                        conns.append(RtlConn(port=binding.port_name, signal=ext.top_name))
                    else:
                        wire_name = f"w_{mod.instance}_{binding.port_name}"
                        src_w = ext.width
                        dst_w = binding.width

                        rtl.add_wire_once(RtlWire(
                            name=wire_name,
                            width=src_w,
                            comment=f"adapter: {binding.port_name} {src_w}b->{dst_w}b ({binding.adapt or 'zero'})",
                        ))
                        conns.append(RtlConn(port=binding.port_name, signal=wire_name))

                        if ext.direction == "input":
                            rhs = f"{ext.top_name}[{min(src_w, dst_w) - 1}:0]"
                            rtl.assigns.append(RtlAssign(
                                lhs=wire_name,
                                rhs=rhs,
                                direction="input",
                                comment="input truncate",
                            ))
                        else:
                            rtl.assigns.append(RtlAssign(
                                lhs=ext.top_name,
                                rhs=self._pad_rhs(
                                    wire=wire_name,
                                    src_w=src_w,
                                    dst_w=dst_w,
                                    pad_mode=binding.adapt or "zero",
                                ),
                                direction="output",
                                comment=f"{binding.adapt or 'zero'} pad",
                            ))
                else:
                    for ext in resolved.resolved:
                        conns.append(RtlConn(port=ext.top_name, signal=ext.top_name))

            rtl.instances.append(RtlInstance(
                module=ip.module,
                name=mod.instance,
                params=mod.params,
                conns=conns,
            ))

            for path in ip.artifacts.synthesis:
                if path not in rtl.extra_sources:
                    rtl.extra_sources.append(path)

        return rtl

    def _pad_rhs(self, *, wire: str, src_w: int, dst_w: int, pad_mode: str) -> str:
        if dst_w > src_w:
            pad = dst_w - src_w
            if pad_mode == "replicate":
                return f"{{ {{{pad}{{ {wire}[{src_w - 1}] }} }}, {wire} }}"
            if pad_mode == "high_z":
                return f"{{ {pad}'bz, {wire} }}"
            return f"{{ {pad}'b0, {wire} }}"
        return f"{wire}[{dst_w - 1}:0]"
```

---

## `socfw/build/context.py`

```python
from __future__ import annotations
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class BuildRequest:
    project_file: str
    out_dir: str


@dataclass(frozen=True)
class BuildContext:
    out_dir: Path
```

---

## `socfw/build/manifest.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class GeneratedArtifact:
    family: str
    path: str
    generator: str


@dataclass
class BuildManifest:
    artifacts: list[GeneratedArtifact] = field(default_factory=list)

    def add(self, family: str, path: str, generator: str) -> None:
        self.artifacts.append(GeneratedArtifact(family=family, path=path, generator=generator))
```

---

## `socfw/plugins/registry.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field

from socfw.validate.rules.base import ValidationRule


@dataclass
class PluginRegistry:
    emitters: dict[str, object] = field(default_factory=dict)
    reports: dict[str, object] = field(default_factory=dict)
    validators: list[ValidationRule] = field(default_factory=list)

    def register_emitter(self, family: str, plugin: object) -> None:
        self.emitters[family] = plugin

    def register_report(self, name: str, plugin: object) -> None:
        self.reports[name] = plugin

    def register_validator(self, rule: ValidationRule) -> None:
        self.validators.append(rule)
```

---

## `socfw/plugins/bootstrap.py`

```python
from __future__ import annotations

from socfw.emit.board_quartus_emitter import QuartusBoardEmitter
from socfw.emit.docs_emitter import DocsEmitter
from socfw.emit.files_tcl_emitter import QuartusFilesEmitter
from socfw.emit.rtl_emitter import RtlEmitter
from socfw.emit.timing_emitter import TimingEmitter
from socfw.plugins.registry import PluginRegistry
from socfw.reports.graphviz_emitter import GraphvizEmitter
from socfw.reports.json_emitter import JsonReportEmitter
from socfw.reports.markdown_emitter import MarkdownReportEmitter
from socfw.validate.rules.asset_rules import VendorIpArtifactExistsRule
from socfw.validate.rules.board_rules import (
    UnknownBoardBindingTargetRule,
    UnknownBoardFeatureRule,
)
from socfw.validate.rules.project_rules import (
    DuplicateModuleInstanceRule,
    UnknownGeneratedClockSourceRule,
    UnknownIpTypeRule,
)


def create_builtin_registry(templates_dir: str) -> PluginRegistry:
    reg = PluginRegistry()

    reg.register_emitter("board", QuartusBoardEmitter())
    reg.register_emitter("rtl", RtlEmitter(templates_dir))
    reg.register_emitter("timing", TimingEmitter(templates_dir))
    reg.register_emitter("files", QuartusFilesEmitter())
    reg.register_emitter("docs", DocsEmitter(templates_dir))

    reg.register_report("json", JsonReportEmitter())
    reg.register_report("markdown", MarkdownReportEmitter())
    reg.register_report("graphviz", GraphvizEmitter())

    reg.register_validator(DuplicateModuleInstanceRule())
    reg.register_validator(UnknownIpTypeRule())
    reg.register_validator(UnknownGeneratedClockSourceRule())
    reg.register_validator(UnknownBoardFeatureRule())
    reg.register_validator(UnknownBoardBindingTargetRule())
    reg.register_validator(VendorIpArtifactExistsRule())

    return reg
```

---

## `socfw/build/pipeline.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field

from socfw.builders.board_ir_builder import BoardIRBuilder
from socfw.builders.rtl_ir_builder import RtlIRBuilder
from socfw.builders.timing_ir_builder import TimingIRBuilder
from socfw.core.diagnostics import Diagnostic, Severity
from socfw.elaborate.planner import Elaborator
from socfw.model.system import SystemModel
from socfw.plugins.registry import PluginRegistry


@dataclass
class BuildResult:
    ok: bool
    diagnostics: list[Diagnostic] = field(default_factory=list)
    manifest: object | None = None
    board_ir: object | None = None
    timing_ir: object | None = None
    rtl_ir: object | None = None
    docs_ir: object | None = None
    design: object | None = None


class BuildPipeline:
    def __init__(self, registry: PluginRegistry) -> None:
        self.registry = registry
        self.elaborator = Elaborator()
        self.board_ir_builder = BoardIRBuilder()
        self.timing_ir_builder = TimingIRBuilder()
        self.rtl_ir_builder = RtlIRBuilder()

    def _validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []

        for msg in system.validate():
            diags.append(Diagnostic(
                code="SYS001",
                severity=Severity.ERROR,
                message=msg,
                subject="system",
            ))

        for rule in self.registry.validators:
            diags.extend(rule.validate(system))

        return diags

    def run(self, request, system: SystemModel) -> BuildResult:
        diags = self._validate(system)
        if any(d.severity == Severity.ERROR for d in diags):
            return BuildResult(ok=False, diagnostics=diags)

        design = self.elaborator.elaborate(system)

        return BuildResult(
            ok=True,
            diagnostics=diags,
            board_ir=self.board_ir_builder.build(design),
            timing_ir=self.timing_ir_builder.build(design),
            rtl_ir=self.rtl_ir_builder.build(design),
            design=design,
        )
```

---

## `socfw/emit/renderer.py`

```python
from __future__ import annotations
from pathlib import Path
from jinja2 import Environment, FileSystemLoader, StrictUndefined


class Renderer:
    def __init__(self, templates_dir: str) -> None:
        self.env = Environment(
            loader=FileSystemLoader(templates_dir),
            undefined=StrictUndefined,
            trim_blocks=True,
            lstrip_blocks=True,
            keep_trailing_newline=True,
        )
        self.env.filters["sv_param"] = self._sv_param

    @staticmethod
    def _sv_param(value: object) -> str:
        if isinstance(value, str) and not value.lstrip("-").isdigit():
            return f'"{value}"'
        return str(value)

    def render(self, template_name: str, **context: object) -> str:
        tmpl = self.env.get_template(template_name)
        return tmpl.render(**context)

    def write_text(self, path: str | Path, content: str, encoding: str = "utf-8") -> None:
        p = Path(path)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content, encoding=encoding)
```

---

## `socfw/emit/rtl_emitter.py`

```python
from __future__ import annotations

from pathlib import Path

from socfw.build.manifest import GeneratedArtifact
from socfw.emit.renderer import Renderer


class RtlEmitter:
    def __init__(self, templates_dir: str) -> None:
        self.renderer = Renderer(templates_dir)

    def emit(self, ctx, ir) -> list[GeneratedArtifact]:
        out = Path(ctx.out_dir) / "rtl" / "soc_top.sv"
        content = self.renderer.render("soc_top.sv.j2", module=ir)
        self.renderer.write_text(out, content, encoding="utf-8")
        return [GeneratedArtifact(family="rtl", path=str(out), generator=self.__class__.__name__)]
```

---

## `socfw/emit/timing_emitter.py`

```python
from __future__ import annotations

from pathlib import Path

from socfw.build.manifest import GeneratedArtifact
from socfw.emit.renderer import Renderer


class TimingEmitter:
    def __init__(self, templates_dir: str) -> None:
        self.renderer = Renderer(templates_dir)

    def emit(self, ctx, ir) -> list[GeneratedArtifact]:
        out = Path(ctx.out_dir) / "timing" / "soc_top.sdc"
        content = self.renderer.render("soc_top.sdc.j2", timing=ir)
        self.renderer.write_text(out, content, encoding="utf-8")
        return [GeneratedArtifact(family="timing", path=str(out), generator=self.__class__.__name__)]
```

---

## `socfw/emit/board_quartus_emitter.py`

```python
from __future__ import annotations

from collections import defaultdict
from pathlib import Path

from socfw.build.manifest import GeneratedArtifact


class QuartusBoardEmitter:
    def emit(self, ctx, ir) -> list[GeneratedArtifact]:
        out = Path(ctx.out_dir) / "hal" / "board.tcl"
        out.parent.mkdir(parents=True, exist_ok=True)

        lines: list[str] = []
        lines.append("# AUTO-GENERATED - DO NOT EDIT")
        lines.append(f'# Device family: {ir.family}')
        lines.append(f"# Device part:   {ir.device}")
        lines.append("")
        lines.append(f'set_global_assignment -name FAMILY "{ir.family}"')
        lines.append(f"set_global_assignment -name DEVICE  {ir.device}")
        lines.append("")

        grouped = defaultdict(list)
        for a in ir.assignments:
            grouped[a.top_name].append(a)

        for top_name in sorted(grouped.keys()):
            pins = sorted(grouped[top_name], key=lambda a: (-1 if a.index is None else a.index))
            sample = pins[0]

            lines.append(f"# {top_name}")
            if sample.io_standard:
                if any(p.index is not None for p in pins):
                    lines.append(f'set_instance_assignment -name IO_STANDARD "{sample.io_standard}" -to {top_name}[*]')
                else:
                    lines.append(f'set_instance_assignment -name IO_STANDARD "{sample.io_standard}" -to {top_name}')
            if sample.weak_pull_up:
                if any(p.index is not None for p in pins):
                    lines.append(f"set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to {top_name}[*]")
                else:
                    lines.append(f"set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to {top_name}")

            for pin in pins:
                if pin.index is None:
                    lines.append(f"set_location_assignment PIN_{pin.pin} -to {top_name}")
                else:
                    lines.append(f"set_location_assignment PIN_{pin.pin} -to {top_name}[{pin.index}]")
            lines.append("")

        out.write_text("\n".join(lines), encoding="ascii")
        return [GeneratedArtifact(family="board", path=str(out), generator=self.__class__.__name__)]
```

---

## `socfw/emit/files_tcl_emitter.py`

```python
from __future__ import annotations

from pathlib import Path

from socfw.build.manifest import GeneratedArtifact


class QuartusFilesEmitter:
    def emit(self, ctx, ir) -> list[GeneratedArtifact]:
        out = Path(ctx.out_dir) / "files.tcl"
        out.parent.mkdir(parents=True, exist_ok=True)

        lines: list[str] = []
        lines.append("# AUTO-GENERATED - DO NOT EDIT")
        lines.append("set_global_assignment -name SYSTEMVERILOG_FILE rtl/soc_top.sv")

        for fp in sorted(ir.extra_sources):
            if fp.endswith(".qip"):
                lines.append(f"set_global_assignment -name QIP_FILE {fp}")
            elif fp.endswith(".sdc"):
                lines.append(f"set_global_assignment -name SDC_FILE {fp}")
            elif fp.endswith(".v"):
                lines.append(f"set_global_assignment -name VERILOG_FILE {fp}")
            elif fp.endswith(".sv"):
                lines.append(f"set_global_assignment -name SYSTEMVERILOG_FILE {fp}")
            elif fp.endswith(".vhd") or fp.endswith(".vhdl"):
                lines.append(f"set_global_assignment -name VHDL_FILE {fp}")
            else:
                lines.append(f"set_global_assignment -name SYSTEMVERILOG_FILE {fp}")

        out.write_text("\n".join(lines) + "\n", encoding="ascii")
        return [GeneratedArtifact(family="files", path=str(out), generator=self.__class__.__name__)]
```

---

## `socfw/emit/docs_emitter.py`

```python
from __future__ import annotations

from pathlib import Path

from socfw.build.manifest import GeneratedArtifact


class DocsEmitter:
    def __init__(self, templates_dir: str) -> None:
        self.templates_dir = templates_dir

    def emit(self, ctx, ir) -> list[GeneratedArtifact]:
        return []
```

---

## `socfw/emit/orchestrator.py`

```python
from __future__ import annotations

from socfw.build.manifest import BuildManifest
from socfw.plugins.registry import PluginRegistry


class EmitOrchestrator:
    def __init__(self, registry: PluginRegistry) -> None:
        self.registry = registry

    def emit_all(self, ctx, *, board_ir, timing_ir, rtl_ir, docs_ir=None) -> BuildManifest:
        manifest = BuildManifest()

        ordered = [
            ("board", board_ir),
            ("rtl", rtl_ir),
            ("timing", timing_ir),
            ("files", rtl_ir),
        ]

        for family, ir in ordered:
            if ir is None:
                continue
            emitter = self.registry.emitters.get(family)
            if emitter is None:
                continue
            for art in emitter.emit(ctx, ir):
                manifest.artifacts.append(art)

        return manifest
```

---

## `socfw/reports/model.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class ReportDiagnostic:
    code: str
    severity: str
    message: str
    subject: str


@dataclass(frozen=True)
class ReportArtifact:
    family: str
    path: str
    generator: str


@dataclass(frozen=True)
class ReportClockDomain:
    name: str
    frequency_hz: int | None
    source_kind: str
    source_ref: str
    reset_policy: str


@dataclass
class BuildReport:
    project_name: str
    board_name: str
    diagnostics: list[ReportDiagnostic] = field(default_factory=list)
    artifacts: list[ReportArtifact] = field(default_factory=list)
    clocks: list[ReportClockDomain] = field(default_factory=list)
```

---

## `socfw/reports/builder.py`

```python
from __future__ import annotations

from socfw.reports.model import BuildReport, ReportArtifact, ReportClockDomain, ReportDiagnostic


class BuildReportBuilder:
    def build(self, *, system, design, result) -> BuildReport:
        report = BuildReport(
            project_name=system.project.name,
            board_name=system.board.board_id,
        )

        for d in result.diagnostics:
            report.diagnostics.append(ReportDiagnostic(
                code=d.code,
                severity=d.severity.value if hasattr(d.severity, "value") else str(d.severity),
                message=d.message,
                subject=d.subject,
            ))

        for a in result.manifest.artifacts:
            report.artifacts.append(ReportArtifact(
                family=a.family,
                path=a.path,
                generator=a.generator,
            ))

        if design is not None:
            for clk in design.clock_domains:
                report.clocks.append(ReportClockDomain(
                    name=clk.name,
                    frequency_hz=clk.frequency_hz,
                    source_kind=clk.source_kind,
                    source_ref=clk.source_ref,
                    reset_policy=clk.reset_policy,
                ))

        return report
```

---

## `socfw/reports/json_emitter.py`

```python
from __future__ import annotations

import json
from dataclasses import asdict
from pathlib import Path


class JsonReportEmitter:
    def emit(self, report, out_dir: str) -> str:
        out = Path(out_dir) / "reports" / "build_report.json"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(asdict(report), indent=2), encoding="utf-8")
        return str(out)
```

---

## `socfw/reports/markdown_emitter.py`

```python
from __future__ import annotations

from pathlib import Path


class MarkdownReportEmitter:
    def emit(self, report, out_dir: str) -> str:
        out = Path(out_dir) / "reports" / "build_report.md"
        out.parent.mkdir(parents=True, exist_ok=True)

        lines: list[str] = []
        lines.append(f"# Build Report: {report.project_name}\n")
        lines.append(f"- Board: `{report.board_name}`")
        lines.append("")

        lines.append("## Diagnostics\n")
        if report.diagnostics:
            lines.append("| Severity | Code | Subject | Message |")
            lines.append("|----------|------|---------|---------|")
            for d in report.diagnostics:
                lines.append(f"| {d.severity} | {d.code} | {d.subject} | {d.message} |")
        else:
            lines.append("No diagnostics.")
        lines.append("")

        lines.append("## Artifacts\n")
        if report.artifacts:
            lines.append("| Family | Generator | Path |")
            lines.append("|--------|-----------|------|")
            for a in report.artifacts:
                lines.append(f"| {a.family} | {a.generator} | `{a.path}` |")
        else:
            lines.append("No artifacts.")
        lines.append("")

        lines.append("## Clock Domains\n")
        if report.clocks:
            lines.append("| Name | Freq (Hz) | Source | Reset |")
            lines.append("|------|-----------|--------|-------|")
            for c in report.clocks:
                freq = "" if c.frequency_hz is None else str(c.frequency_hz)
                lines.append(f"| {c.name} | {freq} | `{c.source_kind}:{c.source_ref}` | {c.reset_policy} |")
        else:
            lines.append("No clock domains.")
        lines.append("")

        out.write_text("\n".join(lines), encoding="utf-8")
        return str(out)
```

---

## `socfw/reports/graph_model.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class GraphNode:
    id: str
    label: str
    kind: str


@dataclass(frozen=True)
class GraphEdge:
    src: str
    dst: str
    label: str = ""
    style: str = "solid"


@dataclass
class SystemGraph:
    nodes: list[GraphNode] = field(default_factory=list)
    edges: list[GraphEdge] = field(default_factory=list)
```

---

## `socfw/reports/graph_builder.py`

```python
from __future__ import annotations

from socfw.reports.graph_model import GraphEdge, GraphNode, SystemGraph


class GraphBuilder:
    def build(self, system, design) -> SystemGraph:
        graph = SystemGraph()

        for mod in system.project.modules:
            graph.nodes.append(GraphNode(
                id=mod.instance,
                label=mod.type_name,
                kind="module",
            ))

        for binding in design.port_bindings:
            for ext in binding.resolved:
                node_id = f"port_{ext.top_name}"
                if all(n.id != node_id for n in graph.nodes):
                    graph.nodes.append(GraphNode(
                        id=node_id,
                        label=ext.top_name,
                        kind="port",
                    ))
                graph.edges.append(GraphEdge(
                    src=binding.instance,
                    dst=node_id,
                    label=binding.port_name,
                ))

        for clk in design.clock_domains:
            node_id = f"clk_{clk.name}"
            graph.nodes.append(GraphNode(
                id=node_id,
                label=clk.name,
                kind="clock",
            ))

        return graph
```

---

## `socfw/reports/graphviz_emitter.py`

```python
from __future__ import annotations

from pathlib import Path


class GraphvizEmitter:
    def emit(self, graph, out_dir: str) -> str:
        out = Path(out_dir) / "reports" / "soc_graph.dot"
        out.parent.mkdir(parents=True, exist_ok=True)

        lines: list[str] = []
        lines.append("digraph soc {")
        lines.append('  graph [rankdir=LR, fontname="Helvetica", bgcolor="#fafafa"];')
        lines.append('  node  [fontname="Helvetica"];')
        lines.append('  edge  [fontname="Helvetica"];')

        for n in graph.nodes:
            shape = {
                "module": "box",
                "port": "diamond",
                "clock": "ellipse",
            }.get(n.kind, "box")
            lines.append(f'  {n.id} [label="{n.label}", shape={shape}];')

        for e in graph.edges:
            extra = f', style={e.style}' if e.style != "solid" else ""
            if e.label:
                lines.append(f'  {e.src} -> {e.dst} [label="{e.label}"{extra}];')
            else:
                lines.append(f'  {e.src} -> {e.dst};')

        lines.append("}")
        out.write_text("\n".join(lines), encoding="utf-8")
        return str(out)
```

---

## `socfw/reports/explain.py`

```python
from __future__ import annotations


class ExplainService:
    def explain_clocks(self, design) -> str:
        lines = ["Clock domains:"]
        for c in design.clock_domains:
            freq = "unknown" if c.frequency_hz is None else f"{c.frequency_hz} Hz"
            lines.append(f"- {c.name}: {freq}, source={c.source_kind}:{c.source_ref}, reset={c.reset_policy}")
        return "\n".join(lines)
```

---

## `socfw/reports/orchestrator.py`

```python
from __future__ import annotations

from socfw.reports.builder import BuildReportBuilder
from socfw.reports.graph_builder import GraphBuilder
from socfw.plugins.registry import PluginRegistry


class ReportOrchestrator:
    def __init__(self, registry: PluginRegistry) -> None:
        self.registry = registry
        self.report_builder = BuildReportBuilder()
        self.graph_builder = GraphBuilder()

    def emit_all(self, *, system, design, result, out_dir: str) -> list[str]:
        paths: list[str] = []

        report = self.report_builder.build(
            system=system,
            design=design,
            result=result,
        )

        if "json" in self.registry.reports:
            paths.append(self.registry.reports["json"].emit(report, out_dir))
        if "markdown" in self.registry.reports:
            paths.append(self.registry.reports["markdown"].emit(report, out_dir))
        if "graphviz" in self.registry.reports:
            graph = self.graph_builder.build(system, design)
            paths.append(self.registry.reports["graphviz"].emit(graph, out_dir))

        return paths
```

---

## `socfw/build/full_pipeline.py`

```python
from __future__ import annotations

from pathlib import Path

from socfw.build.context import BuildContext, BuildRequest
from socfw.build.manifest import BuildManifest
from socfw.build.pipeline import BuildPipeline, BuildResult
from socfw.config.system_loader import SystemLoader
from socfw.emit.orchestrator import EmitOrchestrator
from socfw.plugins.bootstrap import create_builtin_registry
from socfw.reports.orchestrator import ReportOrchestrator


class FullBuildPipeline:
    def __init__(self, templates_dir: str) -> None:
        self.registry = create_builtin_registry(templates_dir)
        self.loader = SystemLoader()
        self.pipeline = BuildPipeline(self.registry)
        self.emitters = EmitOrchestrator(self.registry)
        self.reports = ReportOrchestrator(self.registry)

    def run(self, request: BuildRequest) -> BuildResult:
        loaded = self.loader.load(request.project_file)
        if not loaded.ok or loaded.value is None:
            return BuildResult(ok=False, diagnostics=loaded.diagnostics, manifest=BuildManifest())

        system = loaded.value
        result = self.pipeline.run(request, system)
        result.diagnostics = loaded.diagnostics + result.diagnostics

        if not result.ok:
            result.manifest = BuildManifest()
            return result

        ctx = BuildContext(out_dir=Path(request.out_dir))
        result.manifest = self.emitters.emit_all(
            ctx,
            board_ir=result.board_ir,
            timing_ir=result.timing_ir,
            rtl_ir=result.rtl_ir,
            docs_ir=result.docs_ir,
        )

        report_paths = self.reports.emit_all(
            system=system,
            design=result.design,
            result=result,
            out_dir=request.out_dir,
        )
        for p in report_paths:
            result.manifest.add("report", p, "ReportOrchestrator")

        return result
```

---

## `socfw/cli/main.py`

```python
from __future__ import annotations

import argparse
from pathlib import Path

from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline
from socfw.config.system_loader import SystemLoader
from socfw.elaborate.planner import Elaborator
from socfw.reports.explain import ExplainService


def _default_templates_dir() -> str:
    return str(Path(__file__).resolve().parents[1] / "templates")


def cmd_build(args) -> int:
    pipeline = FullBuildPipeline(templates_dir=args.templates)
    result = pipeline.run(BuildRequest(project_file=args.project, out_dir=args.out))

    for d in result.diagnostics:
        print(f"{d.severity.value.upper()} {d.code}: {d.message}")

    if result.ok:
        for art in result.manifest.artifacts:
            print(f"[{art.family}] {art.path}")

    return 0 if result.ok else 1


def cmd_validate(args) -> int:
    loader = SystemLoader()
    loaded = loader.load(args.project)
    for d in loaded.diagnostics:
        print(f"{d.severity.value.upper()} {d.code}: {d.message}")
    return 0 if loaded.ok else 1


def cmd_explain(args) -> int:
    loader = SystemLoader()
    loaded = loader.load(args.project)

    for d in loaded.diagnostics:
        print(f"{d.severity.value.upper()} {d.code}: {d.message}")

    if not loaded.ok or loaded.value is None:
        return 1

    design = Elaborator().elaborate(loaded.value)
    expl = ExplainService()

    if args.topic == "clocks":
        print(expl.explain_clocks(design))
    else:
        return 1
    return 0


def cmd_graph(args) -> int:
    pipeline = FullBuildPipeline(templates_dir=args.templates)
    result = pipeline.run(BuildRequest(project_file=args.project, out_dir=args.out))

    for d in result.diagnostics:
        print(f"{d.severity.value.upper()} {d.code}: {d.message}")

    if not result.ok:
        return 1

    for art in result.manifest.artifacts:
        if art.family == "report" and art.path.endswith(".dot"):
            print(art.path)
    return 0


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog="socfw")
    sub = ap.add_subparsers(dest="cmd", required=True)

    b = sub.add_parser("build")
    b.add_argument("project")
    b.add_argument("--out", default="build/gen")
    b.add_argument("--templates", default=_default_templates_dir())
    b.set_defaults(func=cmd_build)

    v = sub.add_parser("validate")
    v.add_argument("project")
    v.set_defaults(func=cmd_validate)

    e = sub.add_parser("explain")
    e.add_argument("topic", choices=["clocks"])
    e.add_argument("project")
    e.set_defaults(func=cmd_explain)

    g = sub.add_parser("graph")
    g.add_argument("project")
    g.add_argument("--out", default="build/gen")
    g.add_argument("--templates", default=_default_templates_dir())
    g.set_defaults(func=cmd_graph)

    return ap


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
```

---

## `socfw/templates/soc_top.sv.j2`

```jinja2
// AUTO-GENERATED - DO NOT EDIT
`default_nettype none

module {{ module.name }} (
{%- for p in module.ports %}
  {{ "input " if p.direction == "input" else "output" if p.direction == "output" else "inout " }} wire{% if p.width > 1 %} [{{ p.width - 1 }}:0]{% endif %} {{ p.name }}{{ "," if not loop.last else "" }}
{%- endfor %}
);

{% if module.wires %}
  // Internal wires
{% for w in module.wires %}
  wire{% if w.width > 1 %} [{{ w.width - 1 }}:0]{% endif %} {{ w.name }};{% if w.comment %} // {{ w.comment }}{% endif %}
{% endfor %}

{% endif %}

{% if module.reset_syncs %}
  // Reset synchronizers
{% for rs in module.reset_syncs %}
  rst_sync #(
    .STAGES({{ rs.stages }})
  ) {{ rs.name }} (
    .clk_i   ({{ rs.clk_signal }}),
    .arst_ni (RESET_N),
    .srst_no ({{ rs.rst_out }})
  );
{% endfor %}

{% endif %}

{% if module.assigns %}
  // Top-level / adapter assigns
{% for a in module.assigns %}
  assign {{ a.lhs }} = {{ a.rhs }};{% if a.comment %} // {{ a.comment }}{% endif %}
{% endfor %}

{% endif %}

{% if module.instances %}
  // Module instances
{% for inst in module.instances %}
  {{ inst.module }}
  {%- if inst.params %}
  #(
{%- for k, v in inst.params.items() %}
    .{{ k }}({{ v | sv_param }}){{ "," if not loop.last else "" }}
{%- endfor %}
  )
  {%- endif %}
  u_{{ inst.name }} (
{%- for c in inst.conns %}
    .{{ c.port }}({{ c.signal }}){{ "," if not loop.last else "" }}
{%- endfor %}
  );{% if inst.comment %} // {{ inst.comment }}{% endif %}

{% endfor %}
{% endif %}

endmodule : {{ module.name }}
`default_nettype wire
```

---

## `socfw/templates/soc_top.sdc.j2`

```jinja2
# AUTO-GENERATED - DO NOT EDIT

# Primary clocks
{% for c in timing.clocks -%}
create_clock -name {{ c.name }} -period {{ "%.3f"|format(c.period_ns) }} [get_ports { {{ c.source_port }} }]
{% if c.uncertainty_ns is not none -%}
set_clock_uncertainty {{ "%.3f"|format(c.uncertainty_ns) }} [get_clocks { {{ c.name }} }]
{% endif -%}
{% endfor %}

{% if timing.generated_clocks %}
# Generated clocks
{% for g in timing.generated_clocks -%}
create_generated_clock \
  -name {{ g.name }} \
  -source [get_pins { u_{{ g.source_instance }}|{{ g.source_output }} }] \
  -multiply_by {{ g.multiply_by }} \
  -divide_by {{ g.divide_by }} \
  [get_pins { u_{{ g.source_instance }}|{{ g.source_output }} }]
{% endfor %}

{% endif %}

{% if timing.clock_groups %}
# Clock groups
{% for grp in timing.clock_groups -%}
set_clock_groups -{{ grp.type }}
{%- for group in grp.groups %}
  -group { {% for clk in group %}{{ clk }}{% if not loop.last %} {% endif %}{% endfor %} }
{%- endfor %}
{% endfor %}

{% endif %}

{% if timing.derive_uncertainty %}
derive_clock_uncertainty

{% endif %}

{% if timing.false_paths %}
# False paths
{% for fp in timing.false_paths -%}
{% if fp.from_port %}
set_false_path -from [get_ports { {{ fp.from_port }} }]{% if fp.comment %} ; # {{ fp.comment }}{% endif %}
{% elif fp.from_clock and fp.to_clock %}
set_false_path -from [get_clocks { {{ fp.from_clock }} }] -to [get_clocks { {{ fp.to_clock }} }]{% if fp.comment %} ; # {{ fp.comment }}{% endif %}
{% elif fp.from_cell or fp.to_cell %}
set_false_path{% if fp.from_cell %} -from [get_cells { {{ fp.from_cell }} }]{% endif %}{% if fp.to_cell %} -to [get_cells { {{ fp.to_cell }} }]{% endif %}{% if fp.comment %} ; # {{ fp.comment }}{% endif %}
{% endif -%}
{% endfor %}

{% endif %}

{% if timing.io_delays %}
# IO delays
{% for d in timing.io_delays -%}
{% if d.direction == "input" -%}
set_input_delay -clock [get_clocks { {{ d.clock }} }] -max {{ "%.3f"|format(d.max_ns) }} [get_ports { {{ d.port }} }]
{% if d.min_ns is not none -%}
set_input_delay -clock [get_clocks { {{ d.clock }} }] -min {{ "%.3f"|format(d.min_ns) }} [get_ports { {{ d.port }} }]
{% endif -%}
{% else -%}
set_output_delay -clock [get_clocks { {{ d.clock }} }] -max {{ "%.3f"|format(d.max_ns) }} [get_ports { {{ d.port }} }]
{% if d.min_ns is not none -%}
set_output_delay -clock [get_clocks { {{ d.clock }} }] -min {{ "%.3f"|format(d.min_ns) }} [get_ports { {{ d.port }} }]
{% endif -%}
{% endif -%}
{% if d.comment %}# {{ d.comment }}{% endif %}
{% endfor %}
{% endif %}
```

---

## Minimálny výsledok tejto vetvy

Po vložení týchto súborov a fixture YAML z predošlej správy by si mal dostať prvý fungujúci slice:

```bash
socfw validate tests/golden/fixtures/blink_test_01/project.yaml
socfw build tests/golden/fixtures/blink_test_01/project.yaml --out build/blink01
socfw build tests/golden/fixtures/blink_test_02/project.yaml --out build/blink02
socfw explain clocks tests/golden/fixtures/blink_test_02/project.yaml
socfw graph tests/golden/fixtures/blink_test_02/project.yaml --out build/blink02
```

A to je podľa mňa správny prvý branch pred tým, než sa pustíš do plného `simple_bus`, CPU/RAM a SDRAM vrstvy.

Ak chceš, ďalší krok ti pripravím ako **presný diff čo z tohto minimálneho branchu doplniť do `soc/simple-bus-core`**, aby si vedel pokračovať bez prestavby.
