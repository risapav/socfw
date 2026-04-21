Nižšie nadväzujem priamo na predchádzajúci slice a dopĺňam **kompletné refaktorované YAML loadery + Pydantic schémy + parsery do doménových modelov**.

Tento krok je dôležitý najmä preto, že odstraňuje dnešný problém „voľných dictov + implicitných fallbackov“ a presúva konfiguráciu do striktnejšieho kontraktu. To je presne miesto, kde dnešný framework ešte stále mieša modelové predpoklady naprieč generátormi. Na starom kóde je zároveň vidno, že dobrý smer už existuje: RTL a timing vetva robia veľkú časť transformácie pred renderom, len vstupný model ešte nie je jednotne formalizovaný.   

Nižšie sú súbory v navrhovanej podobe.

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
            raise ValueError(
                f"width={self.width} but pins has {len(self.pins)} entries"
            )
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
            self.top_name is not None
            and self.direction is not None
            and self.pin is not None
            and self.width is None
            and self.pins is None
        )

        simple_vector = (
            self.top_name is not None
            and self.direction is not None
            and self.width is not None
            and self.pins is not None
            and self.pin is None
        )

        complex_bundle = bool(self.signals or self.groups)

        if not (simple_scalar or simple_vector or complex_bundle):
            raise ValueError(
                "resource must be either scalar, vector, or bundle with signals/groups"
            )
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
    package: str | None = None
    pins: int | None = None
    speed: int | None = None
    hdl_default: str | None = None


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


class TimingRootSchema(BaseModel):
    version: Literal[2]
    kind: Literal["timing"]
    timing: dict


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

from socfw.config.board_schema import (
    BoardConfigSchema,
    BoardConnector,
    BoardConnectorRole,
    BoardConnectorRoleSchema,
    BoardModel,
    BoardResetDef,
    BoardResource,
    BoardScalarSignal,
    BoardSystemSchema,
    BoardVectorSignal,
    BoardClockDef,
)
from socfw.config.common import load_yaml_file
from socfw.core.diagnostics import Diagnostic, Severity, SourceRef
from socfw.core.result import Result
from socfw.model.board import PortDir


class BoardLoader:
    def load(self, path: str) -> Result[BoardModel]:
        raw = load_yaml_file(path)
        if not raw.ok:
            return Result(diagnostics=raw.diagnostics)

        try:
            doc = BoardConfigSchema.model_validate(raw.value)
        except ValidationError as exc:
            return Result(
                diagnostics=[
                    Diagnostic(
                        code="BRD100",
                        severity=Severity.ERROR,
                        message=f"Invalid board YAML: {exc}",
                        subject="board",
                        refs=(SourceRef(file=path),),
                    )
                ]
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
            return Result(
                diagnostics=[
                    Diagnostic(
                        code="BRD101",
                        severity=Severity.ERROR,
                        message=msg,
                        subject="board",
                        refs=(SourceRef(file=path),),
                    )
                    for msg in errs
                ]
            )

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
            return Result(
                diagnostics=[
                    Diagnostic(
                        code="IP100",
                        severity=Severity.ERROR,
                        message=f"Invalid IP YAML: {exc}",
                        subject="ip",
                        refs=(SourceRef(file=path),),
                    )
                ]
            )

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
            return Result(
                diagnostics=[
                    Diagnostic(
                        code="IP101",
                        severity=Severity.ERROR,
                        message=msg,
                        subject="ip",
                        refs=(SourceRef(file=path),),
                    )
                    for msg in errs
                ]
            )

        return Result(value=ip)

    def load_catalog(self, search_dirs: list[str]) -> Result[dict[str, IpDescriptor]]:
        catalog: dict[str, IpDescriptor] = {}
        diags: list[Diagnostic] = []

        for root in search_dirs:
            p = Path(root)
            if not p.exists():
                diags.append(
                    Diagnostic(
                        code="IP102",
                        severity=Severity.WARNING,
                        message=f"IP registry path does not exist: {root}",
                        subject="ip.registry",
                        refs=(SourceRef(file=root),),
                    )
                )
                continue

            for fp in sorted(p.rglob("*.ip.yaml")):
                res = self.load_file(str(fp))
                diags.extend(res.diagnostics)
                if res.ok and res.value is not None:
                    ip = res.value
                    if ip.name in catalog:
                        diags.append(
                            Diagnostic(
                                code="IP103",
                                severity=Severity.ERROR,
                                message=f"Duplicate IP descriptor name '{ip.name}'",
                                subject="ip.registry",
                                refs=(SourceRef(file=str(fp)),),
                            )
                        )
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
from socfw.config.project_schema import (
    ModuleClockPortSchema,
    ProjectConfigSchema,
)
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
            return Result(
                diagnostics=[
                    Diagnostic(
                        code="PRJ100",
                        severity=Severity.ERROR,
                        message=f"Invalid project YAML: {exc}",
                        subject="project",
                        refs=(SourceRef(file=path),),
                    )
                ]
            )

        modules: list[ModuleInstance] = []
        for m in doc.modules:
            clocks: list[ClockBinding] = []
            for port_name, value in m.clocks.items():
                if isinstance(value, str):
                    clocks.append(ClockBinding(port_name=port_name, domain=value, no_reset=False))
                else:
                    clocks.append(
                        ClockBinding(
                            port_name=port_name,
                            domain=value.domain,
                            no_reset=value.no_reset,
                        )
                    )

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

            modules.append(
                ModuleInstance(
                    instance=m.instance,
                    type_name=m.type,
                    params=m.params,
                    clocks=clocks,
                    port_bindings=port_bindings,
                )
            )

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
            return Result(
                diagnostics=[
                    Diagnostic(
                        code="PRJ101",
                        severity=Severity.ERROR,
                        message=msg,
                        subject="project",
                        refs=(SourceRef(file=path),),
                    )
                    for msg in errs
                ]
            )

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
            return Result(
                diagnostics=[
                    Diagnostic(
                        code="TIM100",
                        severity=Severity.ERROR,
                        message=f"Invalid timing YAML: {exc}",
                        subject="timing",
                        refs=(SourceRef(file=path),),
                    )
                ]
            )

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
            clock_groups=[
                ClockGroupConstraint(group_type=g.type, groups=g.groups)
                for g in doc.timing.clock_groups
            ],
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
            return Result(
                diagnostics=[
                    Diagnostic(
                        code="TIM101",
                        severity=Severity.ERROR,
                        message=msg,
                        subject="timing",
                        refs=(SourceRef(file=path),),
                    )
                    for msg in errs
                ]
            )

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
            return Result(
                diagnostics=diags + [
                    Diagnostic(
                        code="SYS100",
                        severity=Severity.ERROR,
                        message="project.board_file is required in this minimal loader",
                        subject="project.board_file",
                        refs=(SourceRef(file=project_file),),
                    )
                ]
            )

        board_res = self.board_loader.load(project.board_file)
        diags.extend(board_res.diagnostics)
        if not board_res.ok or board_res.value is None:
            return Result(diagnostics=diags)
        board = board_res.value

        catalog_res = self.ip_loader.load_catalog(project.registries_ip)
        diags.extend(catalog_res.diagnostics)
        if not catalog_res.ok or catalog_res.value is None:
            return Result(diagnostics=diags)
        ip_catalog = catalog_res.value

        timing = None
        if project.timing_file:
            timing_path = Path(project_file).parent / project.timing_file
            tim_res = self.timing_loader.load(str(timing_path))
            diags.extend(tim_res.diagnostics)
            if not tim_res.ok:
                return Result(diagnostics=diags)
            timing = tim_res.value

        system = SystemModel(
            board=board,
            project=project,
            timing=timing,
            ip_catalog=ip_catalog,
        )

        return Result(value=system, diagnostics=diags)
```

---

## `socfw/build/full_pipeline.py`

```python
from __future__ import annotations

from socfw.build.context import BuildRequest
from socfw.build.pipeline import BuildPipeline, BuildResult
from socfw.config.system_loader import SystemLoader


class FullBuildPipeline:
    def __init__(self) -> None:
        self.loader = SystemLoader()
        self.pipeline = BuildPipeline()

    def run(self, request: BuildRequest) -> BuildResult:
        loaded = self.loader.load(request.project_file)
        if not loaded.ok or loaded.value is None:
            return BuildResult(ok=False, diagnostics=loaded.diagnostics)

        result = self.pipeline.run(request, loaded.value)
        result.diagnostics = loaded.diagnostics + result.diagnostics
        return result
```

---

# Čo týmto teraz získavaš

Týmto už máš **kompletnú linku od YAML po IR**:

* board YAML → `BoardModel`
* IP YAML → `IpDescriptor`
* project YAML → `ProjectModel`
* timing YAML → `TimingModel`
* všetko spolu → `SystemModel`
* validácia + elaboration → `ElaboratedDesign`
* buildre → `BoardIR`, `TimingIR`, `RtlModuleIR`

To je ten zásadný architektonický zlom, ktorý dnes framework nemá jednotne zavedený. V starom kóde sa tieto veci robia užitočne, ale po častiach:

* RTL vetva má IR, ale stále ešte aj legacy bridge, 
* timing vetva má dobrý context builder, ale ešte nie samostatný typed IR builder v novom jadre, 
* board/TCL vetva má deterministický výstup, ale pin source of truth je stále v generátore, nie v modeli dosky. 

Tento refaktor to už skladá do jedného konzistentného systému.

# Čo ešte chýba do „prakticky použiteľného“ end-to-end frameworku

Najbližšie veci, ktoré by som doplnil:

* `soc_top.sv.j2` emitter nad `RtlModuleIR`
* `soc_top.sdc.j2` emitter nad `TimingIR`
* `board.tcl` emitter nad `BoardIR` s komentármi/zoskupovaním
* CLI príkazy `validate`, `build`, `explain`
* report JSON/MD
* neskôr bus planner vrstvu

Najrozumnejší ďalší krok je podľa mňa spraviť teraz už **emitre a templaty pre nový `RtlModuleIR` a `TimingIR`**, aby si mal prvý skutočný end-to-end build.

V ďalšej správe ti viem dať:
**kompletné refaktorované emitre + Jinja2 templaty pre `soc_top.sv`, `soc_top.sdc` a `board.tcl`**.
