Super. Toto je správny ďalší krok, lebo po tom, čo už máme jadro pre:

* board / project / timing / IP,
* validation,
* elaboration,
* RTL / timing / board / SW / docs,
* CPU / RAM / IRQ / bus layer,

má najväčšiu pridanú hodnotu práve **reporting a explain vrstva**.

To presne sedí aj na tvoje pôvodné ciele: detailný reporting, validácia, auditovateľnosť a moderná architektúra. Súčasný framework už má niekoľko dobrých zárodkov:

* `soc_map.md` ako ľudský report pre adresový priestor, 
* `soc_graph.dot.j2` ako vizualizáciu SoC topológie, 
* `generated_config.tcl` a `board.tcl` ako deterministické build artefakty, ktoré zvyšujú čitateľnosť flow.  

Nižšie dávam **kompletný refaktorovaný reporting layer**:

* `BuildReport` modely,
* JSON/Markdown emitre,
* graph builder pre interconnect / IRQ / address map,
* napojenie do pipeline.

---

# 1. Report modely

## `socfw/reports/model.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field
from typing import Any


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
    sync_from: str | None = None
    sync_stages: int | None = None


@dataclass(frozen=True)
class ReportAddressRegion:
    name: str
    base: int
    end: int
    size: int
    kind: str
    module: str


@dataclass(frozen=True)
class ReportIrqSource:
    instance: str
    signal: str
    irq_id: int


@dataclass(frozen=True)
class ReportBusEndpoint:
    fabric: str
    instance: str
    module_type: str
    protocol: str
    role: str
    port_name: str
    base: int | None = None
    end: int | None = None
    size: int | None = None


@dataclass(frozen=True)
class PlanningDecision:
    category: str
    message: str
    rationale: str
    related: tuple[str, ...] = ()


@dataclass
class BuildReport:
    project_name: str
    board_name: str
    cpu_type: str
    ram_base: int
    ram_size: int
    reset_vector: int
    diagnostics: list[ReportDiagnostic] = field(default_factory=list)
    artifacts: list[ReportArtifact] = field(default_factory=list)
    clocks: list[ReportClockDomain] = field(default_factory=list)
    address_regions: list[ReportAddressRegion] = field(default_factory=list)
    irq_sources: list[ReportIrqSource] = field(default_factory=list)
    bus_endpoints: list[ReportBusEndpoint] = field(default_factory=list)
    decisions: list[PlanningDecision] = field(default_factory=list)
    metadata: dict[str, Any] = field(default_factory=dict)
```

---

# 2. Report builder

Toto skladá report zo `SystemModel`, `ElaboratedDesign`, `BuildResult`.

## `socfw/reports/builder.py`

```python
from __future__ import annotations

from socfw.build.pipeline import BuildResult
from socfw.elaborate.design import ElaboratedDesign
from socfw.reports.model import (
    BuildReport,
    PlanningDecision,
    ReportAddressRegion,
    ReportArtifact,
    ReportBusEndpoint,
    ReportClockDomain,
    ReportDiagnostic,
    ReportIrqSource,
)


class BuildReportBuilder:
    def build(
        self,
        *,
        system,
        design: ElaboratedDesign | None,
        result: BuildResult,
    ) -> BuildReport:
        report = BuildReport(
            project_name=system.project.name,
            board_name=system.board.board_id,
            cpu_type=system.cpu_type,
            ram_base=system.ram_base,
            ram_size=system.ram_size,
            reset_vector=system.reset_vector,
        )

        for d in result.diagnostics:
            report.diagnostics.append(
                ReportDiagnostic(
                    code=d.code,
                    severity=d.severity.value if hasattr(d.severity, "value") else str(d.severity),
                    message=d.message,
                    subject=d.subject,
                )
            )

        for a in result.manifest.artifacts:
            report.artifacts.append(
                ReportArtifact(
                    family=a.family,
                    path=a.path,
                    generator=a.generator,
                )
            )

        if design is not None:
            for clk in design.clock_domains:
                report.clocks.append(
                    ReportClockDomain(
                        name=clk.name,
                        frequency_hz=clk.frequency_hz,
                        source_kind=clk.source_kind,
                        source_ref=clk.source_ref,
                        reset_policy=clk.reset_policy,
                        sync_from=clk.sync_from,
                        sync_stages=clk.sync_stages,
                    )
                )

            if system.ram is not None:
                report.address_regions.append(
                    ReportAddressRegion(
                        name="RAM",
                        base=system.ram.base,
                        end=system.ram.base + system.ram.size - 1,
                        size=system.ram.size,
                        kind="memory",
                        module=system.ram.module,
                    )
                )

            for p in system.peripheral_blocks:
                report.address_regions.append(
                    ReportAddressRegion(
                        name=p.instance,
                        base=p.base,
                        end=p.end,
                        size=p.size,
                        kind="peripheral",
                        module=p.module,
                    )
                )

            if design.irq_plan is not None:
                for src in design.irq_plan.sources:
                    report.irq_sources.append(
                        ReportIrqSource(
                            instance=src.instance,
                            signal=src.signal_name,
                            irq_id=src.irq_id,
                        )
                    )

            if design.interconnect is not None:
                for fabric, endpoints in design.interconnect.fabrics.items():
                    for ep in endpoints:
                        report.bus_endpoints.append(
                            ReportBusEndpoint(
                                fabric=fabric,
                                instance=ep.instance,
                                module_type=ep.module_type,
                                protocol=ep.protocol,
                                role=ep.role,
                                port_name=ep.port_name,
                                base=ep.base,
                                end=ep.end,
                                size=ep.size,
                            )
                        )

            report.decisions.extend(self._build_decisions(system, design))

        return report

    def _build_decisions(self, system, design: ElaboratedDesign) -> list[PlanningDecision]:
        decisions: list[PlanningDecision] = []

        if design.interconnect is not None:
            for fabric, endpoints in design.interconnect.fabrics.items():
                proto = endpoints[0].protocol if endpoints else "unknown"
                decisions.append(
                    PlanningDecision(
                        category="bus",
                        message=f"Built fabric '{fabric}' with protocol '{proto}'",
                        rationale="Fabric protocol selected from project bus_fabrics configuration",
                        related=(fabric, proto),
                    )
                )

        for clk in design.clock_domains:
            decisions.append(
                PlanningDecision(
                    category="clock",
                    message=f"Resolved clock domain '{clk.name}' from {clk.source_kind}",
                    rationale=f"Clock domain source resolved from '{clk.source_ref}'",
                    related=(clk.name, clk.source_ref),
                )
            )

        if design.irq_plan is not None and design.irq_plan.sources:
            decisions.append(
                PlanningDecision(
                    category="irq",
                    message=f"Built IRQ plan with width {design.irq_plan.width}",
                    rationale="IRQ width derived from max peripheral IRQ id",
                    related=tuple(src.instance for src in design.irq_plan.sources),
                )
            )

        if system.ram is not None:
            decisions.append(
                PlanningDecision(
                    category="memory",
                    message=f"Configured RAM region at 0x{system.ram.base:08X} size {system.ram.size}",
                    rationale="RAM model taken from project memory configuration",
                    related=("RAM", system.ram.module),
                )
            )

        return decisions
```

---

# 3. JSON report emitter

## `socfw/reports/json_emitter.py`

```python
from __future__ import annotations

import json
from dataclasses import asdict
from pathlib import Path

from socfw.reports.model import BuildReport


class JsonReportEmitter:
    def emit(self, report: BuildReport, out_dir: str) -> str:
        out = Path(out_dir) / "reports" / "build_report.json"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(asdict(report), indent=2), encoding="utf-8")
        return str(out)
```

---

# 4. Markdown report emitter

## `socfw/reports/markdown_emitter.py`

```python
from __future__ import annotations

from pathlib import Path

from socfw.reports.model import BuildReport


class MarkdownReportEmitter:
    def emit(self, report: BuildReport, out_dir: str) -> str:
        out = Path(out_dir) / "reports" / "build_report.md"
        out.parent.mkdir(parents=True, exist_ok=True)

        lines: list[str] = []
        lines.append(f"# Build Report: {report.project_name}\n")
        lines.append(f"- Board: `{report.board_name}`")
        lines.append(f"- CPU: `{report.cpu_type}`")
        lines.append(f"- RAM: `{report.ram_size}` B @ `0x{report.ram_base:08X}`")
        lines.append(f"- Reset vector: `0x{report.reset_vector:08X}`")
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
                lines.append(
                    f"| {c.name} | {freq} | `{c.source_kind}:{c.source_ref}` | {c.reset_policy} |"
                )
        else:
            lines.append("No clock domains.")
        lines.append("")

        lines.append("## Address Map\n")
        if report.address_regions:
            lines.append("| Name | Base | End | Size | Kind | Module |")
            lines.append("|------|------|-----|------|------|--------|")
            for r in sorted(report.address_regions, key=lambda x: x.base):
                lines.append(
                    f"| {r.name} | `0x{r.base:08X}` | `0x{r.end:08X}` | {r.size} | {r.kind} | {r.module} |"
                )
        else:
            lines.append("No address regions.")
        lines.append("")

        lines.append("## IRQ Sources\n")
        if report.irq_sources:
            lines.append("| ID | Instance | Signal |")
            lines.append("|----|----------|--------|")
            for irq in sorted(report.irq_sources, key=lambda x: x.irq_id):
                lines.append(f"| {irq.irq_id} | {irq.instance} | `{irq.signal}` |")
        else:
            lines.append("No IRQ sources.")
        lines.append("")

        lines.append("## Bus Endpoints\n")
        if report.bus_endpoints:
            lines.append("| Fabric | Instance | Module | Role | Protocol | Base | End |")
            lines.append("|--------|----------|--------|------|----------|------|-----|")
            for ep in report.bus_endpoints:
                base = "" if ep.base is None else f"`0x{ep.base:08X}`"
                end = "" if ep.end is None else f"`0x{ep.end:08X}`"
                lines.append(
                    f"| {ep.fabric} | {ep.instance} | {ep.module_type} | {ep.role} | {ep.protocol} | {base} | {end} |"
                )
        else:
            lines.append("No bus endpoints.")
        lines.append("")

        lines.append("## Planning Decisions\n")
        if report.decisions:
            for d in report.decisions:
                lines.append(f"- **{d.category}**: {d.message} — {d.rationale}")
        else:
            lines.append("No planning decisions.")
        lines.append("")

        out.write_text("\n".join(lines), encoding="utf-8")
        return str(out)
```

Toto je moderný a systematický nástupca starého `soc_map.md`, len už ako integrovaný build report, nie izolovaný dokument. 

---

# 5. Graph builder

Graph vrstva by mala mať vlastný model, nie priamo templating nad starým SoC modelom.

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

        if system.cpu is not None:
            graph.nodes.append(
                GraphNode(
                    id="cpu",
                    label=system.cpu.cpu_type,
                    kind="cpu",
                )
            )

        if system.ram is not None:
            graph.nodes.append(
                GraphNode(
                    id="ram",
                    label=f"RAM\\n0x{system.ram.base:08X}..0x{system.ram.base + system.ram.size - 1:08X}",
                    kind="memory",
                )
            )

        for p in system.peripheral_blocks:
            graph.nodes.append(
                GraphNode(
                    id=p.instance,
                    label=f"{p.instance}\\n0x{p.base:08X}",
                    kind="peripheral",
                )
            )

        if design.interconnect is not None:
            for fabric, endpoints in design.interconnect.fabrics.items():
                fabric_id = f"fabric_{fabric}"
                proto = endpoints[0].protocol if endpoints else "unknown"
                graph.nodes.append(
                    GraphNode(
                        id=fabric_id,
                        label=f"{fabric}\\n({proto})",
                        kind="fabric",
                    )
                )

                for ep in endpoints:
                    if ep.role == "master":
                        graph.edges.append(
                            GraphEdge(
                                src=ep.instance,
                                dst=fabric_id,
                                label=ep.protocol,
                            )
                        )
                    else:
                        graph.edges.append(
                            GraphEdge(
                                src=fabric_id,
                                dst=ep.instance,
                                label=ep.protocol,
                            )
                        )

        if design.irq_plan is not None and system.cpu is not None:
            for src in design.irq_plan.sources:
                graph.edges.append(
                    GraphEdge(
                        src=src.instance,
                        dst="cpu",
                        label=f"IRQ {src.irq_id}",
                        style="dashed",
                    )
                )

        return graph
```

Toto je typed nástupca funkcie, ktorú dnes supluje `soc_graph.dot.j2` nad starým kontextom. 

---

# 6. Graphviz emitter

## `socfw/reports/graphviz_emitter.py`

```python
from __future__ import annotations

from pathlib import Path

from socfw.reports.graph_model import SystemGraph


class GraphvizEmitter:
    def emit(self, graph: SystemGraph, out_dir: str) -> str:
        out = Path(out_dir) / "reports" / "soc_graph.dot"
        out.parent.mkdir(parents=True, exist_ok=True)

        lines: list[str] = []
        lines.append("digraph soc {")
        lines.append('  graph [rankdir=LR, fontname="Helvetica", bgcolor="#fafafa"];')
        lines.append('  node  [fontname="Helvetica"];')
        lines.append('  edge  [fontname="Helvetica"];')

        for n in graph.nodes:
            shape = {
                "cpu": "box3d",
                "memory": "cylinder",
                "peripheral": "box",
                "fabric": "ellipse",
            }.get(n.kind, "box")
            lines.append(f'  {n.id} [label="{n.label}", shape={shape}];')

        for e in graph.edges:
            extra = f', style={e.style}' if e.style != "solid" else ""
            if e.label:
                lines.append(f'  {e.src} -> {e.dst} [label="{e.label}"{extra}];')
            else:
                lines.append(f'  {e.src} -> {e.dst} [{extra.lstrip(", ")}];')

        lines.append("}")
        out.write_text("\n".join(lines), encoding="utf-8")
        return str(out)
```

---

# 7. Explain outputs

Toto je jednoduchá, ale veľmi užitočná vrstva. Nie každý používateľ chce hneď JSON alebo DOT; často chce len rýchle vysvetlenie.

## `socfw/reports/explain.py`

```python
from __future__ import annotations


class ExplainService:
    def explain_clocks(self, design) -> str:
        lines = ["Clock domains:"]
        for c in design.clock_domains:
            freq = "unknown" if c.frequency_hz is None else f"{c.frequency_hz} Hz"
            lines.append(
                f"- {c.name}: {freq}, source={c.source_kind}:{c.source_ref}, reset={c.reset_policy}"
            )
        return "\n".join(lines)

    def explain_address_map(self, system) -> str:
        lines = ["Address map:"]
        if system.ram is not None:
            lines.append(
                f"- RAM: 0x{system.ram.base:08X} .. 0x{system.ram.base + system.ram.size - 1:08X}"
            )
        for p in sorted(system.peripheral_blocks, key=lambda x: x.base):
            lines.append(f"- {p.instance}: 0x{p.base:08X} .. 0x{p.end:08X} ({p.module})")
        return "\n".join(lines)

    def explain_irqs(self, design) -> str:
        if design.irq_plan is None or not design.irq_plan.sources:
            return "No IRQ sources."
        lines = [f"IRQ map (width={design.irq_plan.width}):"]
        for src in design.irq_plan.sources:
            lines.append(f"- irq[{src.irq_id}] <- {src.instance}.{src.signal_name}")
        return "\n".join(lines)
```

---

# 8. Reporting suite

## `socfw/reports/run_reports.py`

```python
from __future__ import annotations

from socfw.reports.builder import BuildReportBuilder
from socfw.reports.graph_builder import GraphBuilder
from socfw.reports.graphviz_emitter import GraphvizEmitter
from socfw.reports.json_emitter import JsonReportEmitter
from socfw.reports.markdown_emitter import MarkdownReportEmitter


class ReportSuite:
    def __init__(self) -> None:
        self.report_builder = BuildReportBuilder()
        self.json = JsonReportEmitter()
        self.md = MarkdownReportEmitter()
        self.graph_builder = GraphBuilder()
        self.graphviz = GraphvizEmitter()

    def emit_all(self, *, system, design, result, out_dir: str) -> list[str]:
        paths: list[str] = []

        report = self.report_builder.build(
            system=system,
            design=design,
            result=result,
        )
        paths.append(self.json.emit(report, out_dir))
        paths.append(self.md.emit(report, out_dir))

        graph = self.graph_builder.build(system, design)
        paths.append(self.graphviz.emit(graph, out_dir))

        return paths
```

---

# 9. Napojenie do full pipeline

## `socfw/build/full_pipeline.py`

```python
from __future__ import annotations

from pathlib import Path

from socfw.build.context import BuildContext, BuildRequest
from socfw.build.pipeline import BuildPipeline, BuildResult
from socfw.config.system_loader import SystemLoader
from socfw.emit.run_emitters import EmitterSuite
from socfw.builders.boot_image_builder import BootImageBuilder
from socfw.reports.run_reports import ReportSuite
from socfw.tools.bin2hex_runner import Bin2HexRunner


class FullBuildPipeline:
    def __init__(self, templates_dir: str) -> None:
        self.loader = SystemLoader()
        self.pipeline = BuildPipeline()
        self.emitters = EmitterSuite(templates_dir)
        self.image_builder = BootImageBuilder()
        self.bin2hex = Bin2HexRunner()
        self.reports = ReportSuite()

    def run(self, request: BuildRequest) -> BuildResult:
        loaded = self.loader.load(request.project_file)
        if not loaded.ok or loaded.value is None:
            return BuildResult(ok=False, diagnostics=loaded.diagnostics)

        system = loaded.value
        result = self.pipeline.run(request, system)
        result.diagnostics = loaded.diagnostics + result.diagnostics

        if not result.ok:
            return result

        ctx = BuildContext(out_dir=Path(request.out_dir))
        manifest = self.emitters.emit_all(
            ctx,
            board_ir=result.board_ir,
            timing_ir=result.timing_ir,
            rtl_ir=result.rtl_ir,
            software_ir=result.software_ir,
            docs_ir=result.docs_ir,
            register_block_irs=result.register_block_irs,
        )
        result.manifest = manifest

        image = self.image_builder.build(system, request.out_dir)
        if image is not None and image.input_format == "bin" and image.output_format == "hex":
            conv = self.bin2hex.run(image)
            result.diagnostics.extend(conv.diagnostics)

        # reporting
        design = self.pipeline.elaborator.elaborate(system)
        report_paths = self.reports.emit_all(
            system=system,
            design=design,
            result=result,
            out_dir=request.out_dir,
        )
        for p in report_paths:
            result.manifest.add("report", p, "ReportSuite")

        return result
```

Poznámka: tu sa elaboration volá druhý raz. To je v poriadku pre prvý slice, ale neskôr je lepšie, aby `BuildPipeline.run()` vracal aj `design`, aby sa nepocítaval znovu.

---

# 10. Lepšia verzia: uložiť `design` do `BuildResult`

## `socfw/build/pipeline.py`

Doplniť do `BuildResult`:

```python
    design: object | None = None
```

A pri return:

```python
        return BuildResult(
            ok=True,
            diagnostics=diags,
            board_ir=board_ir,
            timing_ir=timing_ir,
            rtl_ir=rtl_ir,
            software_ir=software_ir,
            docs_ir=docs_ir,
            register_block_irs=regblk_irs,
            design=design,
        )
```

A potom vo `full_pipeline.py` použiť `result.design`.

---

# 11. Čo týmto už máš

Po tomto kroku má framework už aj **developer experience layer**, nie len generačné jadro.

Vieš dostať:

* JSON build report
* Markdown build report
* Graphviz topológiu
* explain-style texty pre:

  * clock tree
  * address map
  * IRQ map

A to je presne ten typ hodnoty, ktorý starý framework zatiaľ poskytuje len fragmentovane:

* `soc_map.md` len pre mapu, 
* `soc_graph.dot.j2` len pre graph, 
* build decisions a diagnostics ešte nie sú integrované v jednom modeli.

---

# 12. Čo ešte chýba do naozaj silného frameworku

Po tomto bode už nejde o chýbajúce jadro, ale skôr o vyzretosť:

### 1. plugin registry a dynamic discovery

Zatiaľ sme väčšinu vecí skladali staticky.

### 2. cache/incremental build

Keď sa zmení len docs alebo timing, nemusí sa prebuildovať všetko.

### 3. richer bridge/adapters

`axi_lite`, `wishbone`, width adapters, ready-latency policies.

### 4. stronger CLI

`validate`, `build`, `explain`, `graph`, `doctor`, `schema export`.

### 5. test harness

golden tests, fixture configs, snapshot comparisons.

---

# 13. Môj odporúčaný ďalší krok

Teraz už by som nešiel do ďalších doménových vrstiev, ale do **produkčného spevnenia frameworku**:

* plugin registry,
* CLI,
* unit/integration/golden test layout,
* project skeleton,
* sample configs.

To je moment, kde sa z architektúrne dobrého návrhu stane použiteľný framework.

V ďalšej správe ti viem pripraviť:
**kompletný refaktorovaný plugin registry + CLI + test layout**
tak, aby si mal už aj dobrý základ pre reálne repo a postupnú implementáciu.
