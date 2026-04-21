Nižšie je prvý **ucelený refaktorovaný slice**, ktorý už tvorí použiteľné jadro pre ďalší vývoj:

* nové IR vrstvy,
* tri buildre,
* jednoduchá build pipeline,
* bez legacy bridge v RTL,
* bez hardcoded board DB v generátore,
* s prenesením správnych nápadov zo starého `rtl_builder.py`, `rtl_context.py`, `sdc.py` a `tcl.py` do čistejších vrstiev.    

Toto ber ako **prvý kompletný refaktorovaný balík súborov**, na ktorom sa dá ďalej stavať.

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

    def add_scalar(
        self,
        *,
        top_name: str,
        pin: str,
        io_standard: str | None = None,
        weak_pull_up: bool = False,
    ) -> None:
        self.assignments.append(
            BoardPinAssignment(
                top_name=top_name,
                index=None,
                pin=pin,
                io_standard=io_standard,
                weak_pull_up=weak_pull_up,
            )
        )

    def add_vector(
        self,
        *,
        top_name: str,
        pins: dict[int, str],
        io_standard: str | None = None,
        weak_pull_up: bool = False,
    ) -> None:
        for idx, pin in sorted(pins.items()):
            self.assignments.append(
                BoardPinAssignment(
                    top_name=top_name,
                    index=idx,
                    pin=pin,
                    io_standard=io_standard,
                    weak_pull_up=weak_pull_up,
                )
            )
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

    @property
    def width_str(self) -> str:
        return f"[{self.width - 1}:0]" if self.width > 1 else ""


@dataclass(frozen=True)
class RtlWire:
    name: str
    width: int = 1
    comment: str = ""

    @property
    def width_str(self) -> str:
        return f"[{self.width - 1}:0]" if self.width > 1 else ""


@dataclass(frozen=True)
class RtlAssign:
    lhs: str
    rhs: str
    direction: str = "comb"   # input / output / comb
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

Toto je priamy nástupca súčasného `RtlContext/RtlModule`, ale bez `_bus_context` a bez dočasného legacy mosta pre SoC mode.  

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
        self.artifacts.append(
            GeneratedArtifact(
                family=family,
                path=path,
                generator=generator,
            )
        )
```

---

## `socfw/build/pipeline.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field
from pathlib import Path

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.build.context import BuildContext, BuildRequest
from socfw.build.manifest import BuildManifest
from socfw.elaborate.planner import Elaborator
from socfw.model.system import SystemModel
from socfw.validate.rules.asset_rules import VendorIpArtifactExistsRule
from socfw.validate.rules.binding_rules import BindingWidthCompatibilityRule
from socfw.validate.rules.board_rules import (
    UnknownBoardBindingTargetRule,
    UnknownBoardFeatureRule,
)
from socfw.validate.rules.project_rules import (
    DuplicateModuleInstanceRule,
    UnknownGeneratedClockSourceRule,
    UnknownIpTypeRule,
)
from socfw.builders.board_ir_builder import BoardIRBuilder
from socfw.builders.timing_ir_builder import TimingIRBuilder
from socfw.builders.rtl_ir_builder import RtlIRBuilder


@dataclass
class BuildResult:
    ok: bool
    diagnostics: list[Diagnostic] = field(default_factory=list)
    manifest: BuildManifest = field(default_factory=BuildManifest)
    board_ir: object | None = None
    timing_ir: object | None = None
    rtl_ir: object | None = None


class BuildPipeline:
    """
    Minimal in-memory pipeline.
    Loaders/emitters are intentionally external so this slice stays focused on
    model validation + elaboration + IR building.
    """

    def __init__(self) -> None:
        self.rules = [
            DuplicateModuleInstanceRule(),
            UnknownIpTypeRule(),
            UnknownGeneratedClockSourceRule(),
            UnknownBoardFeatureRule(),
            UnknownBoardBindingTargetRule(),
            VendorIpArtifactExistsRule(),
            BindingWidthCompatibilityRule(),
        ]
        self.elaborator = Elaborator()
        self.board_ir_builder = BoardIRBuilder()
        self.timing_ir_builder = TimingIRBuilder()
        self.rtl_ir_builder = RtlIRBuilder()

    def _validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []

        for msg in system.validate():
            diags.append(
                Diagnostic(
                    code="SYS001",
                    severity=Severity.ERROR,
                    message=msg,
                    subject="system",
                )
            )

        for rule in self.rules:
            diags.extend(rule.validate(system))

        return diags

    def run(self, request: BuildRequest, system: SystemModel) -> BuildResult:
        ctx = BuildContext(out_dir=Path(request.out_dir))
        manifest = BuildManifest()

        diags = self._validate(system)
        if any(d.severity == Severity.ERROR for d in diags):
            return BuildResult(ok=False, diagnostics=diags, manifest=manifest)

        design = self.elaborator.elaborate(system)

        board_ir = self.board_ir_builder.build(design)
        timing_ir = self.timing_ir_builder.build(design)
        rtl_ir = self.rtl_ir_builder.build(design)

        return BuildResult(
            ok=True,
            diagnostics=diags,
            manifest=manifest,
            board_ir=board_ir,
            timing_ir=timing_ir,
            rtl_ir=rtl_ir,
        )
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

        # System clock/reset are always present.
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

        # Resolved bindings decide which board resources are actually used.
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

Tento builder nahrádza starý prístup, kde sa Quartus pin assignments skladali z hardcoded `_ONB_PINS`, `_PMOD_PINS` a runtime filtrov nad `m.onboard`/`m.pmod`. Teraz pin fakty berie z board modelu a použitie z elaborated bindings.  

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
            ir.clocks.append(
                ClockConstraint(
                    name=clk.name,
                    source_port=clk.source_port,
                    period_ns=clk.period_ns,
                    uncertainty_ns=clk.uncertainty_ns,
                )
            )

            if clk.reset_port:
                ir.false_paths.append(
                    FalsePathConstraintIR(
                        from_port=clk.reset_port,
                        comment=f"Async reset for domain {clk.name}",
                    )
                )

        for gclk in timing.generated_clocks:
            ir.generated_clocks.append(
                GeneratedClockConstraint(
                    name=gclk.name,
                    source_instance=gclk.source_instance,
                    source_output=gclk.source_clock,
                    source_clock=gclk.source_clock,
                    multiply_by=gclk.multiply_by,
                    divide_by=gclk.divide_by,
                    pin_index=gclk.pin_index,
                    phase_shift_ps=gclk.phase_shift_ps,
                )
            )

            if gclk.sync_from:
                ir.false_paths.append(
                    FalsePathConstraintIR(
                        from_clock=gclk.sync_from,
                        to_clock=gclk.name,
                        comment=(
                            f"CDC reset sync: {gclk.sync_from} -> {gclk.name} "
                            f"({gclk.sync_stages or 2}-stage FF)"
                        ),
                    )
                )

        for grp in timing.clock_groups:
            ir.clock_groups.append(
                {
                    "type": grp.group_type,
                    "groups": grp.groups,
                }
            )

        for fp in timing.false_paths:
            ir.false_paths.append(
                FalsePathConstraintIR(
                    from_port=fp.from_port,
                    from_clock=fp.from_clock,
                    to_clock=fp.to_clock,
                    from_cell=fp.from_cell,
                    to_cell=fp.to_cell,
                    comment=fp.comment,
                )
            )

        if timing.io_auto:
            override_ports = {ov.port for ov in timing.io_overrides}
            default_clock = timing.io_default_clock

            for binding in design.port_bindings:
                for ext in binding.resolved:
                    if ext.top_name in override_ports:
                        continue

                    direction = "input" if ext.direction == "input" else "output"
                    max_ns = (
                        timing.io_default_input_max_ns
                        if direction == "input"
                        else timing.io_default_output_max_ns
                    )
                    if default_clock and max_ns is not None:
                        ir.io_delays.append(
                            IoDelayConstraintIR(
                                port=ext.top_name,
                                direction=direction,
                                clock=default_clock,
                                max_ns=max_ns,
                                comment=f"{binding.instance}.{binding.port_name}",
                            )
                        )

        for ov in timing.io_overrides:
            ir.io_delays.append(
                IoDelayConstraintIR(
                    port=ov.port,
                    direction=ov.direction,
                    clock=ov.clock,
                    max_ns=ov.max_ns,
                    min_ns=ov.min_ns,
                    comment=ov.comment,
                )
            )

        return ir
```

Toto vedome preberá dobrý princíp zo starého `sdc.py`: všetka podstatná logika sa deje pred renderom a šablóna má zostať len formátovanie. 

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

        # System ports are always present.
        rtl.add_port_once(RtlPort(name=BOARD_CLOCK, direction="input", width=1))
        rtl.add_port_once(RtlPort(name=BOARD_RESET, direction="input", width=1))

        # Collect top-level external ports from resolved board bindings.
        for binding in design.port_bindings:
            for ext in binding.resolved:
                rtl.add_port_once(
                    RtlPort(
                        name=ext.top_name,
                        direction=ext.direction,
                        width=ext.width,
                    )
                )

        # Reset sync plan from resolved clock domains.
        for dom in design.clock_domains:
            if dom.reset_policy == "synced" and dom.name != system.project.primary_clock_domain:
                rst_out = f"rst_n_{dom.name}"
                rtl.add_wire_once(RtlWire(name=dom.name, width=1, comment="clock domain"))
                rtl.add_wire_once(RtlWire(name=rst_out, width=1, comment="reset sync output"))
                rtl.reset_syncs.append(
                    RtlResetSync(
                        name=f"u_rst_sync_{dom.name}",
                        stages=dom.sync_stages or 2,
                        clk_signal=dom.name,
                        rst_out=rst_out,
                    )
                )
            elif dom.source_kind == "generated":
                rtl.add_wire_once(RtlWire(name=dom.name, width=1, comment="generated clock"))

        # Build module instances.
        for mod in system.project.modules:
            ip = system.ip_catalog.get(mod.type_name)
            if ip is None:
                continue

            conns: list[RtlConn] = []

            # Connect clock/reset ports from project clock bindings.
            for cb in mod.clocks:
                signal = cb.domain
                if cb.domain == system.project.primary_clock_domain:
                    signal = BOARD_CLOCK
                conns.append(RtlConn(port=cb.port_name, signal=signal))

                if not cb.no_reset and ip.reset.port:
                    if cb.domain == system.project.primary_clock_domain:
                        rst_sig = BOARD_RESET
                    else:
                        rst_sig = f"rst_n_{cb.domain}"

                    if ip.reset.active_high:
                        rst_sig = f"~{rst_sig}"
                    conns.append(RtlConn(port=ip.reset.port, signal=rst_sig))

            # External board bindings.
            for binding in mod.port_bindings:
                resolved = next(
                    (b for b in design.port_bindings
                     if b.instance == mod.instance and b.port_name == binding.port_name),
                    None,
                )
                if resolved is None:
                    continue

                # Single simple target: direct or adapted connect
                if len(resolved.resolved) == 1:
                    ext = resolved.resolved[0]

                    needs_adapter = binding.width is not None and binding.width != ext.width
                    if not needs_adapter:
                        conns.append(RtlConn(port=binding.port_name, signal=ext.top_name))
                    else:
                        wire_name = f"w_{mod.instance}_{binding.port_name}"
                        src_w = ext.width
                        dst_w = binding.width

                        rtl.add_wire_once(
                            RtlWire(
                                name=wire_name,
                                width=src_w,
                                comment=(
                                    f"adapter: {binding.port_name} "
                                    f"{src_w}b->{dst_w}b ({binding.adapt or 'zero'})"
                                ),
                            )
                        )
                        conns.append(RtlConn(port=binding.port_name, signal=wire_name))

                        if ext.direction == "input":
                            rhs = f"{ext.top_name}[{min(src_w, dst_w) - 1}:0]"
                            rtl.assigns.append(
                                RtlAssign(
                                    lhs=wire_name,
                                    rhs=rhs,
                                    direction="input",
                                    comment="input truncate",
                                )
                            )
                        else:
                            rtl.assigns.append(
                                RtlAssign(
                                    lhs=ext.top_name,
                                    rhs=self._pad_rhs(
                                        wire=wire_name,
                                        src_w=src_w,
                                        dst_w=dst_w,
                                        pad_mode=binding.adapt or "zero",
                                    ),
                                    direction="output",
                                    comment=f"{binding.adapt or 'zero'} pad",
                                )
                            )
                else:
                    # Complex bundle binding (e.g. SDRAM group)
                    # Convention: IP ports are expected to match top_name values or explicit design-time port names.
                    for ext in resolved.resolved:
                        conns.append(RtlConn(port=ext.top_name, signal=ext.top_name))

            rtl.instances.append(
                RtlInstance(
                    module=ip.module,
                    name=mod.instance,
                    params=mod.params,
                    conns=conns,
                )
            )

            # Vendor-generated or dependency assets become extra sources.
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

Tento builder je priamy pokračovateľ dnešného `RtlBuilder`:

* zachováva dobrý width-adapter model,
* zachováva direction-aware assigny,
* zavádza reset sync wires z resolved clock domains,
* ale už neberie `SoCModel` a netreba mu žiadny `_bus_context` ani board port injection hack v generátore.   

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

Toto zámerne neopakuje staré `base.write()` správanie, ktoré všetko nasilu transliteruje na ASCII. To je vhodné pre niektoré Quartus súbory, ale nie ako univerzálna politika pre celé jadro. 

---

## `socfw/emit/board_quartus_emitter.py`

```python
from __future__ import annotations
from pathlib import Path

from socfw.build.context import BuildContext
from socfw.build.manifest import GeneratedArtifact
from socfw.ir.board import BoardIR


class QuartusBoardEmitter:
    family = "board"

    def emit(self, ctx: BuildContext, ir: BoardIR) -> list[GeneratedArtifact]:
        out = Path(ctx.out_dir) / "hal" / "board.tcl"
        out.parent.mkdir(parents=True, exist_ok=True)

        lines: list[str] = []
        lines.append(f'set_global_assignment -name FAMILY "{ir.family}"')
        lines.append(f"set_global_assignment -name DEVICE  {ir.device}")
        lines.append("")

        grouped: dict[tuple[str, str | None, bool], list[tuple[int | None, str]]] = {}
        for a in ir.assignments:
            key = (a.top_name, a.io_standard, a.weak_pull_up)
            grouped.setdefault(key, []).append((a.index, a.pin))

        for (top_name, io_standard, weak_pull_up), pins in grouped.items():
            if io_standard:
                if any(idx is not None for idx, _ in pins):
                    lines.append(
                        f'set_instance_assignment -name IO_STANDARD "{io_standard}" -to {top_name}[*]'
                    )
                else:
                    lines.append(
                        f'set_instance_assignment -name IO_STANDARD "{io_standard}" -to {top_name}'
                    )
            if weak_pull_up:
                if any(idx is not None for idx, _ in pins):
                    lines.append(
                        f"set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to {top_name}[*]"
                    )
                else:
                    lines.append(
                        f"set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to {top_name}"
                    )

            for idx, pin in sorted(pins, key=lambda x: (-1 if x[0] is None else x[0])):
                if idx is None:
                    lines.append(f"set_location_assignment PIN_{pin} -to {top_name}")
                else:
                    lines.append(f"set_location_assignment PIN_{pin} -to {top_name}[{idx}]")
            lines.append("")

        out.write_text("\n".join(lines), encoding="ascii")
        return [GeneratedArtifact(family=self.family, path=str(out), generator=self.__class__.__name__)]
```

Toto je už prvý emitter, ktorý sa opiera o `BoardIR` namiesto hardcoded Quartus BSP mapy v generátore. To je presne refaktor, ktorý starý `tcl.py` potrebuje.  

---

## `socfw/emit/files_tcl_emitter.py`

```python
from __future__ import annotations
from pathlib import Path

from socfw.build.context import BuildContext
from socfw.build.manifest import GeneratedArtifact
from socfw.ir.rtl import RtlModuleIR


class QuartusFilesEmitter:
    family = "files"

    def emit(self, ctx: BuildContext, ir: RtlModuleIR) -> list[GeneratedArtifact]:
        out = Path(ctx.out_dir) / "files.tcl"
        out.parent.mkdir(parents=True, exist_ok=True)

        lines: list[str] = []
        lines.append("set_global_assignment -name SYSTEMVERILOG_FILE gen/rtl/soc_top.sv")

        for fp in ir.extra_sources:
            if fp.endswith(".qip"):
                lines.append(f"set_global_assignment -name QIP_FILE {fp}")
            elif fp.endswith(".sdc"):
                lines.append(f"set_global_assignment -name SDC_FILE {fp}")
            elif fp.endswith(".v"):
                lines.append(f"set_global_assignment -name VERILOG_FILE {fp}")
            elif fp.endswith(".vhd") or fp.endswith(".vhdl"):
                lines.append(f"set_global_assignment -name VHDL_FILE {fp}")
            else:
                lines.append(f"set_global_assignment -name SYSTEMVERILOG_FILE {fp}")

        out.write_text("\n".join(lines) + "\n", encoding="ascii")
        return [GeneratedArtifact(family=self.family, path=str(out), generator=self.__class__.__name__)]
```

Tu sa priamo prenáša dobrý princíp zo starého `files.tcl.j2`, ale zdrojom už nie je plochý zoznam z legacy generátora — ale `rtl_ir.extra_sources`, kam sa dostali vendor IP assety z IP descriptorov. 

---

## `socfw/emit/software_ir.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class SwRegister:
    peripheral: str
    name: str
    address: int
    access: str
    desc: str = ""


@dataclass
class SoftwareIR:
    sys_clk_hz: int
    ram_base: int
    ram_size: int
    reset_vector: int
    stack_percent: int
    registers: list[SwRegister] = field(default_factory=list)
```

---

## `socfw/builders/software_ir_builder.py`

```python
from __future__ import annotations

from socfw.elaborate.design import ElaboratedDesign
from socfw.emit.software_ir import SoftwareIR


class SoftwareIRBuilder:
    """
    Placeholder builder for the future SoC flow.
    In standalone-only examples without bus/register blocks this can still
    emit base memory constants if project metadata contains them later.
    """

    def build(self, design: ElaboratedDesign) -> SoftwareIR | None:
        # This will become meaningful once CPU/RAM/address-space are modeled
        # in the new SystemModel.
        return None
```

Toto zatiaľ zámerne nechávam ako placeholder, lebo na plnohodnotný `SoftwareIRBuilder` ešte potrebuješ explicitný CPU/RAM/address-space model. Ale smer je rovnaký ako v starom `SWGenerator`: jeden zdroj pravdy pre `soc_map.h`, linker script a docs.  

---

# Čo by som spravil hneď ako ďalší krok

Teraz už máš ucelený slice, takže ďalší logický krok je:

1. doplniť **YAML loadery** pre board/project/timing/ip do týchto modelov,
2. spraviť **Jinja emitre** pre:

   * `soc_top.sv`
   * `soc_top.sdc`
   * `board.tcl`
3. doplniť **SoC/address-space model** pre software IR,
4. potom pridať **bus planner pluginy**.

Najdôležitejšie je, že týmto návrhom sa už:

* board facts presunuli z generátora do board modelu,
* vendor-generated IP sa prenášajú cez asset bundle,
* RTL builder už nepotrebuje legacy kontextové hacky,
* timing logika je znova builder-first, nie template-first.   

Ak chceš, v ďalšej správe nadviažem a dám ti aj **kompletné refaktorované YAML loadery + Pydantic schémy + parser do týchto modelov**.
