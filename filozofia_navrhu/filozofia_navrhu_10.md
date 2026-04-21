Super. Nižšie dávam už **prvý implementovateľný balík kódu** pre nové jadro:

* `model/board.py`
* `model/project.py`
* `model/ip.py`
* `model/timing.py`
* `validate/rules/*.py`
* `elaborate/board_bindings.py`
* `elaborate/clocks.py`

Návrh je robený tak, aby:

* sedel na tvoje YAML v2 rozdelenie board/project/timing/IP,
* vedel nahradiť dnešné implicitné väzby v standalone flow,
* zachoval dobré veci zo súčasného frameworku, hlavne explicitné width adaptation a clock/reset planning, ale bez legacy bridge vrstiev. Súčasný `RtlBuilder` je na toto dobrá inšpirácia hlavne v častiach okolo adapterov, deduplikácie a validácie signálov.  
* zároveň presunul board pin databázu z generátora do board modelu, čo je presne smer, ktorý si už naznačil board YAML návrhom a ktorý dnešný `tcl.py` ešte nemá, lebo pin mapu drží priamo v kóde.  

---

# 1. `model/board.py`

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
            errs.append(
                f"{self.key}: width={self.width} but {len(self.pins)} pins provided"
            )
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
        """
        Supported refs:
          board:onboard.leds
          board:onboard.sdram
          board:connector.pmod.J10.role.led8
        """
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
                    errs.append(
                        f"Duplicate top_name '{role.top_name}' in connector.{conn_name}.role.{role_name}"
                    )
                seen_top_names.add(role.top_name)
                if len(role.pins) != role.width:
                    errs.append(
                        f"connector.{conn_name}.role.{role_name}: width={role.width} "
                        f"but {len(role.pins)} pins provided"
                    )

        return errs
```

Tento model už priamo zodpovedá tomu, čo dnes board YAML nesie ako shared hardware facts a čo `tcl.py` zatiaľ drží natvrdo v BSP mapách.  

---

# 2. `model/ip.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field
from typing import Any


@dataclass(frozen=True)
class IpOrigin:
    kind: str                    # source, vendor_generated, generated
    tool: str | None = None      # quartus, vivado, ...
    packaging: str | None = None # qip, xci, plain_rtl, ...


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
    kind: str                    # generated_clock, status
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
    category: str                    # standalone, peripheral, internal_dependency
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
            errs.append(
                f"{self.name}: dependency_only and instantiate_directly cannot both be true"
            )

        if self.origin.kind == "vendor_generated" and not self.artifacts.synthesis:
            errs.append(
                f"{self.name}: vendor_generated IP must declare synthesis artifacts"
            )

        if self.reset.bypass_sync and self.reset.port is None:
            errs.append(f"{self.name}: bypass_sync requires reset.port")

        return errs
```

Toto je priamo pripravené pre `clkpll` a `sdram_fifo`, kde sú dôležité:

* `origin.kind = vendor_generated`
* `qip` ako synthesis artifact
* explicitná reset semantika
* clock outputs planner-visible, nielen ako obyčajné porty.  

---

# 3. `model/project.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field
from typing import Any


@dataclass(frozen=True)
class PortBinding:
    port_name: str
    target: str                    # board:onboard.leds, board:connector.pmod.J10.role.led8, ...
    top_name: str | None = None
    width: int | None = None
    adapt: str | None = None       # zero, replicate, high_z


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

Toto priamo mapuje dnešné `modules`, `clock_domains`, `port_overrides` a `timing.file` do konzistentného modelu.   

---

# 4. `model/timing.py`

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

    def all_clock_names(self) -> set[str]:
        return (
            {c.name for c in self.primary_clocks}
            | {g.name for g in self.generated_clocks}
        )

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

Toto je zjednotený model pre dnešný `timing_config.yaml` a zároveň pekne sedí na transformačnú logiku v `sdc.py`, ktorá už dnes robí odvodenie generated clocks, false paths a IO delays ešte pred renderom. 

---

# 5. `model/system.py`

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

# 6. `validate/rules/base.py`

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

# 7. `validate/rules/project_rules.py`

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
                diags.append(
                    Diagnostic(
                        code="PRJ001",
                        severity=Severity.ERROR,
                        message=f"Duplicate module instance '{mod.instance}'",
                        subject="project.modules",
                    )
                )
            seen.add(mod.instance)

        return diags


class UnknownIpTypeRule(ValidationRule):
    def validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []

        for mod in system.project.modules:
            if mod.type_name not in system.ip_catalog:
                diags.append(
                    Diagnostic(
                        code="PRJ002",
                        severity=Severity.ERROR,
                        message=f"Unknown IP type '{mod.type_name}' for instance '{mod.instance}'",
                        subject="project.modules",
                    )
                )

        return diags


class UnknownGeneratedClockSourceRule(ValidationRule):
    def validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []

        for req in system.project.generated_clocks:
            inst = system.project.module_by_name(req.source_instance)
            if inst is None:
                diags.append(
                    Diagnostic(
                        code="CLK001",
                        severity=Severity.ERROR,
                        message=f"Generated clock '{req.domain}' references unknown instance '{req.source_instance}'",
                        subject="project.clocks.generated",
                    )
                )
                continue

            ip = system.ip_catalog.get(inst.type_name)
            if ip is None:
                continue

            out = ip.clocking.find_output(req.source_output)
            if out is None:
                diags.append(
                    Diagnostic(
                        code="CLK002",
                        severity=Severity.ERROR,
                        message=(
                            f"Generated clock '{req.domain}' references unknown output "
                            f"'{req.source_output}' on IP '{inst.type_name}'"
                        ),
                        subject="project.clocks.generated",
                    )
                )
                continue

            if out.kind != "generated_clock":
                diags.append(
                    Diagnostic(
                        code="CLK003",
                        severity=Severity.ERROR,
                        message=(
                            f"Output '{req.source_output}' on IP '{inst.type_name}' "
                            f"is '{out.kind}', not a generated_clock"
                        ),
                        subject="project.clocks.generated",
                    )
                )

        return diags
```

---

# 8. `validate/rules/board_rules.py`

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
                diags.append(
                    Diagnostic(
                        code="BRD001",
                        severity=Severity.ERROR,
                        message=str(e),
                        subject="project.features.use",
                    )
                )

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
                        diags.append(
                            Diagnostic(
                                code="BRD002",
                                severity=Severity.ERROR,
                                message=(
                                    f"Instance '{mod.instance}' port '{binding.port_name}': {e}"
                                ),
                                subject="project.modules.bind.ports",
                            )
                        )

        return diags
```

---

# 9. `validate/rules/asset_rules.py`

```python
from __future__ import annotations
from pathlib import Path

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.model.system import SystemModel
from .base import ValidationRule


class VendorIpArtifactExistsRule(ValidationRule):
    """
    Soft validation: only checks literal files in descriptor paths.
    Search-path aware resolution can be added later in loader/catalog layer.
    """

    def validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []

        for ip in system.ip_catalog.values():
            if ip.origin.kind != "vendor_generated":
                continue

            for path in ip.artifacts.synthesis:
                if not Path(path).exists():
                    diags.append(
                        Diagnostic(
                            code="AST001",
                            severity=Severity.WARNING,
                            message=f"Vendor IP '{ip.name}' synthesis artifact not found: {path}",
                            subject="ip.artifacts.synthesis",
                        )
                    )

        return diags
```

Toto je cielene warning, nie error, lebo neskôr bude lepšie robiť search-path aware rozlíšenie cez registry loader.

---

# 10. `validate/rules/binding_rules.py`

```python
from __future__ import annotations

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.model.system import SystemModel
from socfw.model.board import BoardResource, BoardConnectorRole
from .base import ValidationRule


class BindingWidthCompatibilityRule(ValidationRule):
    def validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []

        for mod in system.project.modules:
            ip = system.ip_catalog.get(mod.type_name)
            if ip is None:
                continue

            for b in mod.port_bindings:
                if not b.target.startswith("board:"):
                    continue

                try:
                    target = system.board.resolve_ref(b.target)
                except KeyError:
                    continue

                resolved_width = None
                if isinstance(target, BoardConnectorRole):
                    resolved_width = target.width
                elif isinstance(target, BoardResource):
                    sig = target.default_signal()
                    if sig is not None and hasattr(sig, "width"):
                        resolved_width = sig.width
                    elif sig is not None:
                        resolved_width = 1

                if b.width is not None and resolved_width is not None and b.width != resolved_width:
                    # allowed but noteworthy because adaptation will be needed
                    diags.append(
                        Diagnostic(
                            code="BND001",
                            severity=Severity.INFO,
                            message=(
                                f"Instance '{mod.instance}' port '{b.port_name}' binds to width "
                                f"{resolved_width} via explicit width {b.width}; adapter will be required"
                            ),
                            subject="project.modules.bind.ports",
                        )
                    )

        return diags
```

Toto je zámerne len INFO, lebo width mismatch sám o sebe nemusí byť chyba; dnešný framework to už vie správne riešiť pomocou adapter wire + assign logiky. 

---

# 11. `elaborate/board_bindings.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field

from socfw.model.board import BoardResource, BoardConnectorRole
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
                        # complex bundle, e.g. SDRAM
                        parts: list[ResolvedExternalPort] = []
                        for sig in target.scalars.values():
                            parts.append(
                                ResolvedExternalPort(
                                    top_name=sig.top_name,
                                    direction=sig.direction.value,
                                    width=1,
                                    io_standard=sig.io_standard,
                                    pin=sig.pin,
                                    weak_pull_up=sig.weak_pull_up,
                                )
                            )
                        for vec in target.vectors.values():
                            parts.append(
                                ResolvedExternalPort(
                                    top_name=vec.top_name,
                                    direction=vec.direction.value,
                                    width=vec.width,
                                    io_standard=vec.io_standard,
                                    pins=vec.pins,
                                    weak_pull_up=vec.weak_pull_up,
                                )
                            )
                        resolved = tuple(parts)
                else:
                    raise TypeError(f"Unsupported board target type: {type(target)}")

                result.append(
                    ResolvedPortBinding(
                        instance=mod.instance,
                        port_name=binding.port_name,
                        target_ref=binding.target,
                        resolved=resolved,
                        adapt=binding.adapt,
                    )
                )

        return result
```

Toto je kľúčová vrstva, ktorá nahrádza dnešné implicitné miešanie board facts a top-port injection. Dnešný `rtl.py` síce správne rieši, že top-level port sa má objaviť len keď ho modul skutočne potrebuje, ale robí to neskoro a cez starý model. Tu sa to prenáša do čistej elaboration vrstvy. 

---

# 12. `elaborate/clocks.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field

from socfw.model.system import SystemModel


@dataclass(frozen=True)
class ResolvedClockDomain:
    name: str
    frequency_hz: int | None
    source_kind: str            # board | generated
    source_ref: str
    reset_policy: str           # synced | bypassed | none
    sync_from: str | None = None
    sync_stages: int | None = None


class ClockResolver:
    def resolve(self, system: SystemModel) -> list[ResolvedClockDomain]:
        domains: list[ResolvedClockDomain] = []

        # primary board clock
        domains.append(
            ResolvedClockDomain(
                name=system.project.primary_clock_domain,
                frequency_hz=system.board.sys_clock.frequency_hz,
                source_kind="board",
                source_ref=system.board.sys_clock.top_name,
                reset_policy="synced",
                sync_stages=2,
            )
        )

        # generated clocks
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
                # bypass applies to IP reset input semantics; generated domain still
                # may require CDC-synced reset if sync_from specified
                reset_policy = "synced" if req.sync_from else "none"
            else:
                reset_policy = "synced" if req.sync_from else "none"

            domains.append(
                ResolvedClockDomain(
                    name=req.domain,
                    frequency_hz=req.frequency_hz,
                    source_kind="generated",
                    source_ref=f"{req.source_instance}.{req.source_output}",
                    reset_policy=reset_policy,
                    sync_from=req.sync_from,
                    sync_stages=req.sync_stages,
                )
            )

        return domains
```

Toto priamo sedí na tvoje prípady:

* `sys_clk` z board clocku,
* `clk_100mhz` a `clk_100mhz_sh` z `clkpll`,
* možnosť `no_reset: true` pri shifted SDRAM clocku.
  A zároveň rešpektuje fakt, že `clkpll` v IP descriptoroch nesie špecifickú reset semantiku.   

---

# 13. `elaborate/design.py`

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

# 14. `elaborate/planner.py`

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

        # collect dependency assets from used module types
        used_types = {m.type_name for m in system.project.modules}
        for t in used_types:
            ip = system.ip_catalog.get(t)
            if ip is None:
                continue
            design.dependency_assets.extend(ip.artifacts.synthesis)

        return design
```

---

# 15. Prečo je tento balík dobrý prvý krok

Tento kód ti dá hneď niekoľko dôležitých vecí:

* jasný **doménový model** oddelený od YAML a od emitorov,
* prvé použiteľné **validation rules**,
* reálnu **elaboration vrstvu** pre board bindings a generated clocks,
* základ, na ktorý sa dá hneď napojiť `BoardIRBuilder`, `TimingIRBuilder` a `RtlIRBuilder`.

A hlavne: týmto sa zlomí dnešný pattern, kde sa dôležitá časť top-level port a board logiky rieši až priamo v RTL generátore alebo v hardcoded Quartus generatori. Súčasné generátory sú už na viacerých miestach správne transform-oriented, ale stále ešte miešajú planning a emission. Tento návrh to rozdeľuje čistejšie.   

---

# 16. Čo by som implementoval hneď potom

Najbližší ďalší krok by som spravil:

* `builders/board_ir_builder.py`
* `builders/timing_ir_builder.py`
* `builders/rtl_ir_builder.py`

pričom:

* `BoardIRBuilder` vezme resolved port bindings a board model a urobí pin assignments pre Quartus,
* `TimingIRBuilder` vezme `TimingModel + ResolvedClockDomain` a spraví create_clock/generated_clock/false_path IR,
* `RtlIRBuilder` vezme module instances + resolved bindings + clock domains a postaví nový čistý `RtlModuleIR`.

To je moment, kde už budeš mať kostru, na ktorú sa dá reálne generovať.

V ďalšej správe ti viem pripraviť práve tieto tri buildre ako konkrétny Python návrh.
