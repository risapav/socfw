Nižšie je ďalší ucelený krok: **plugin registry + CLI + test layout**, už v podobe, ktorá sa dá priamo použiť ako základ reálneho repozitára.

Cieľ tejto vrstvy je:

* oddeliť core od konkrétnych pluginov,
* umožniť registráciu board/IP/bus/emitter/report pluginov,
* spraviť čisté CLI príkazy,
* pripraviť štruktúru pre unit, integration a golden testy.

---

# 1. Plugin registry

## `socfw/plugins/registry.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field
from typing import Protocol, Any

from socfw.validate.rules.base import ValidationRule


class BusPlannerPlugin(Protocol):
    protocol: str

    def plan(self, system: Any) -> Any:
        ...


class LoaderPlugin(Protocol):
    kind: str

    def load(self, *args, **kwargs) -> Any:
        ...


class EmitterPlugin(Protocol):
    family: str

    def emit(self, *args, **kwargs) -> list[Any]:
        ...


class ReportPlugin(Protocol):
    name: str

    def emit(self, *args, **kwargs) -> str | list[str]:
        ...


@dataclass
class PluginRegistry:
    bus_planners: dict[str, BusPlannerPlugin] = field(default_factory=dict)
    loaders: dict[str, LoaderPlugin] = field(default_factory=dict)
    emitters: dict[str, EmitterPlugin] = field(default_factory=dict)
    reports: dict[str, ReportPlugin] = field(default_factory=dict)
    validators: list[ValidationRule] = field(default_factory=list)

    def register_bus_planner(self, plugin: BusPlannerPlugin) -> None:
        self.bus_planners[plugin.protocol] = plugin

    def register_loader(self, plugin: LoaderPlugin) -> None:
        self.loaders[plugin.kind] = plugin

    def register_emitter(self, plugin: EmitterPlugin) -> None:
        self.emitters[plugin.family] = plugin

    def register_report(self, plugin: ReportPlugin) -> None:
        self.reports[plugin.name] = plugin

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
from socfw.emit.register_block_emitter import RegisterBlockEmitter
from socfw.emit.rtl_emitter import RtlEmitter
from socfw.emit.software_emitter import SoftwareEmitter
from socfw.emit.timing_emitter import TimingEmitter
from socfw.plugins.registry import PluginRegistry
from socfw.plugins.simple_bus.planner import SimpleBusPlanner
from socfw.reports.graphviz_emitter import GraphvizEmitter
from socfw.reports.json_emitter import JsonReportEmitter
from socfw.reports.markdown_emitter import MarkdownReportEmitter
from socfw.validate.rules.asset_rules import VendorIpArtifactExistsRule
from socfw.validate.rules.binding_rules import BindingWidthCompatibilityRule
from socfw.validate.rules.board_rules import (
    UnknownBoardBindingTargetRule,
    UnknownBoardFeatureRule,
)
from socfw.validate.rules.bus_rules import (
    DuplicateAddressRegionRule,
    FabricProtocolMismatchRule,
    MissingBusInterfaceRule,
    UnknownBusFabricRule,
)
from socfw.validate.rules.project_rules import (
    DuplicateModuleInstanceRule,
    UnknownGeneratedClockSourceRule,
    UnknownIpTypeRule,
)


def create_builtin_registry(templates_dir: str) -> PluginRegistry:
    reg = PluginRegistry()

    reg.register_bus_planner(SimpleBusPlanner())

    reg.register_emitter(QuartusBoardEmitter())
    reg.register_emitter(RtlEmitter(templates_dir))
    reg.register_emitter(TimingEmitter(templates_dir))
    reg.register_emitter(QuartusFilesEmitter())
    reg.register_emitter(SoftwareEmitter(templates_dir))
    reg.register_emitter(DocsEmitter(templates_dir))
    reg.register_emitter(RegisterBlockEmitter(templates_dir))

    reg.register_report(JsonReportEmitter())
    reg.register_report(MarkdownReportEmitter())
    reg.register_report(GraphvizEmitter())

    reg.register_validator(DuplicateModuleInstanceRule())
    reg.register_validator(UnknownIpTypeRule())
    reg.register_validator(UnknownGeneratedClockSourceRule())
    reg.register_validator(UnknownBoardFeatureRule())
    reg.register_validator(UnknownBoardBindingTargetRule())
    reg.register_validator(VendorIpArtifactExistsRule())
    reg.register_validator(BindingWidthCompatibilityRule())
    reg.register_validator(UnknownBusFabricRule())
    reg.register_validator(MissingBusInterfaceRule())
    reg.register_validator(DuplicateAddressRegionRule())
    reg.register_validator(FabricProtocolMismatchRule())

    return reg
```

---

# 2. Pipeline napojená na registry

## `socfw/build/pipeline.py`

Toto je refaktor tak, aby pipeline nepoznala konkrétne plugin triedy natvrdo.

```python
from __future__ import annotations
from dataclasses import dataclass, field

from socfw.build.context import BuildRequest
from socfw.build.manifest import BuildManifest
from socfw.builders.board_ir_builder import BoardIRBuilder
from socfw.builders.docs_ir_builder import DocsIRBuilder
from socfw.builders.register_block_ir_builder import RegisterBlockIRBuilder
from socfw.builders.rtl_ir_builder import RtlIRBuilder
from socfw.builders.software_ir_builder import SoftwareIRBuilder
from socfw.builders.timing_ir_builder import TimingIRBuilder
from socfw.core.diagnostics import Diagnostic, Severity
from socfw.elaborate.planner import Elaborator
from socfw.model.system import SystemModel
from socfw.plugins.registry import PluginRegistry


@dataclass
class BuildResult:
    ok: bool
    diagnostics: list[Diagnostic] = field(default_factory=list)
    manifest: BuildManifest = field(default_factory=BuildManifest)
    board_ir: object | None = None
    timing_ir: object | None = None
    rtl_ir: object | None = None
    software_ir: object | None = None
    docs_ir: object | None = None
    register_block_irs: list[object] = field(default_factory=list)
    design: object | None = None


class BuildPipeline:
    def __init__(self, registry: PluginRegistry) -> None:
        self.registry = registry
        self.elaborator = Elaborator()
        self.board_ir_builder = BoardIRBuilder()
        self.timing_ir_builder = TimingIRBuilder()
        self.rtl_ir_builder = RtlIRBuilder()
        self.software_ir_builder = SoftwareIRBuilder()
        self.docs_ir_builder = DocsIRBuilder()
        self.regblk_ir_builder = RegisterBlockIRBuilder()

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

        for rule in self.registry.validators:
            diags.extend(rule.validate(system))

        return diags

    def run(self, request: BuildRequest, system: SystemModel) -> BuildResult:
        diags = self._validate(system)
        if any(d.severity == Severity.ERROR for d in diags):
            return BuildResult(ok=False, diagnostics=diags)

        design = self.elaborator.elaborate(system)

        board_ir = self.board_ir_builder.build(design)
        timing_ir = self.timing_ir_builder.build(design)
        rtl_ir = self.rtl_ir_builder.build(design)
        software_ir = self.software_ir_builder.build(design)
        docs_ir = self.docs_ir_builder.build(design)

        regblk_irs = []
        for p in system.peripheral_blocks:
            regblk = self.regblk_ir_builder.build_for_peripheral(p)
            if regblk is not None:
                regblk_irs.append(regblk)

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

---

# 3. Emission orchestrator cez registry

## `socfw/emit/orchestrator.py`

```python
from __future__ import annotations

from socfw.build.context import BuildContext
from socfw.build.manifest import BuildManifest
from socfw.plugins.registry import PluginRegistry


class EmitOrchestrator:
    def __init__(self, registry: PluginRegistry) -> None:
        self.registry = registry

    def emit_all(
        self,
        ctx: BuildContext,
        *,
        board_ir,
        timing_ir,
        rtl_ir,
        software_ir=None,
        docs_ir=None,
        register_block_irs=None,
    ) -> BuildManifest:
        manifest = BuildManifest()

        ordered = [
            ("board", board_ir),
            ("rtl", rtl_ir),
            ("timing", timing_ir),
            ("files", rtl_ir),
            ("software", software_ir),
            ("docs", docs_ir),
        ]

        for family, ir in ordered:
            if ir is None:
                continue
            emitter = self.registry.emitters.get(family)
            if emitter is None:
                continue
            for art in emitter.emit(ctx, ir):
                manifest.artifacts.append(art)

        if register_block_irs:
            emitter = self.registry.emitters.get("rtl_regs")
            if emitter is not None:
                for art in emitter.emit_many(ctx, register_block_irs):
                    manifest.artifacts.append(art)

        return manifest
```

---

# 4. Reporting orchestrator cez registry

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
            p = self.registry.reports["json"].emit(report, out_dir)
            paths.append(p)

        if "markdown" in self.registry.reports:
            p = self.registry.reports["markdown"].emit(report, out_dir)
            paths.append(p)

        if "graphviz" in self.registry.reports:
            graph = self.graph_builder.build(system, design)
            p = self.registry.reports["graphviz"].emit(graph, out_dir)
            paths.append(p)

        return paths
```

---

# 5. Full pipeline cez registry

## `socfw/build/full_pipeline.py`

```python
from __future__ import annotations

from pathlib import Path

from socfw.build.context import BuildContext, BuildRequest
from socfw.build.pipeline import BuildPipeline, BuildResult
from socfw.builders.boot_image_builder import BootImageBuilder
from socfw.config.system_loader import SystemLoader
from socfw.emit.orchestrator import EmitOrchestrator
from socfw.plugins.bootstrap import create_builtin_registry
from socfw.reports.orchestrator import ReportOrchestrator
from socfw.tools.bin2hex_runner import Bin2HexRunner


class FullBuildPipeline:
    def __init__(self, templates_dir: str) -> None:
        self.registry = create_builtin_registry(templates_dir)
        self.loader = SystemLoader()
        self.pipeline = BuildPipeline(self.registry)
        self.emitters = EmitOrchestrator(self.registry)
        self.reports = ReportOrchestrator(self.registry)
        self.image_builder = BootImageBuilder()
        self.bin2hex = Bin2HexRunner()

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

# 6. CLI

Navrhujem CLI s týmito príkazmi:

* `build`
* `validate`
* `explain clocks`
* `explain address-map`
* `explain irqs`
* `graph`

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

    system = loaded.value
    design = Elaborator().elaborate(system)
    expl = ExplainService()

    if args.topic == "clocks":
        print(expl.explain_clocks(design))
    elif args.topic == "address-map":
        print(expl.explain_address_map(system))
    elif args.topic == "irqs":
        print(expl.explain_irqs(design))
    else:
        print(f"Unknown explain topic: {args.topic}")
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
    e.add_argument("topic", choices=["clocks", "address-map", "irqs"])
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

# 7. Test layout

Odporúčaná štruktúra:

```text
tests/
  unit/
    test_board_loader.py
    test_ip_loader.py
    test_project_loader.py
    test_timing_loader.py
    test_bus_rules.py
    test_rtl_ir_builder.py
    test_software_ir_builder.py
    test_report_builder.py

  integration/
    test_blink_build.py
    test_blink_pll_build.py
    test_sdram_build.py

  golden/
    fixtures/
      blink_test_01/
        project.yaml
        board.yaml
        ip/
      blink_test_02/
        project.yaml
        board.yaml
        ip/
      sdram_test/
        project.yaml
        timing.yaml
        board.yaml
        ip/
    expected/
      blink_test_01/
        rtl/soc_top.sv
        hal/board.tcl
        reports/build_report.md
      blink_test_02/
        rtl/soc_top.sv
        timing/soc_top.sdc
        reports/soc_graph.dot
      sdram_test/
        rtl/soc_top.sv
        sw/soc_map.h
        docs/soc_map.md
```

---

# 8. Unit test examples

## `tests/unit/test_board_loader.py`

```python
from socfw.config.board_loader import BoardLoader


def test_load_board_minimal(tmp_path):
    fp = tmp_path / "board.yaml"
    fp.write_text(
        """
version: 2
kind: board
board:
  id: test_board
  vendor: Test
  title: Test Board
fpga:
  family: Cyclone IV E
  part: EP4CE55F23C8
system:
  clock:
    id: sys_clk
    top_name: SYS_CLK
    pin: T2
    frequency_hz: 50000000
  reset:
    id: sys_reset_n
    top_name: RESET_N
    pin: W13
    active_low: true
resources:
  onboard: {}
  connectors: {}
""",
        encoding="utf-8",
    )

    res = BoardLoader().load(str(fp))
    assert res.ok
    assert res.value is not None
    assert res.value.board_id == "test_board"
    assert res.value.sys_clock.top_name == "SYS_CLK"
```

---

## `tests/unit/test_bus_rules.py`

```python
from socfw.validate.rules.bus_rules import DuplicateAddressRegionRule


def test_duplicate_address_region_rule(system_with_overlapping_peripherals):
    diags = DuplicateAddressRegionRule().validate(system_with_overlapping_peripherals)
    assert any(d.code == "BUS003" for d in diags)
```

---

# 9. Integration test examples

## `tests/integration/test_blink_build.py`

```python
from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline


def test_blink_build(tmp_path):
    templates = "socfw/templates"
    project = "tests/golden/fixtures/blink_test_01/project.yaml"
    out_dir = tmp_path / "out"

    pipeline = FullBuildPipeline(templates_dir=templates)
    result = pipeline.run(BuildRequest(project_file=project, out_dir=str(out_dir)))

    assert result.ok
    assert (out_dir / "rtl" / "soc_top.sv").exists()
    assert (out_dir / "hal" / "board.tcl").exists()
    assert (out_dir / "reports" / "build_report.json").exists()
```

---

# 10. Golden tests

Golden test porovná konkrétne artefakty s očakávaným výstupom.

## `tests/golden/test_golden_outputs.py`

```python
from pathlib import Path

from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline


def _read(p: Path) -> str:
    return p.read_text(encoding="utf-8")


def test_blink_test_01_golden(tmp_path):
    templates = "socfw/templates"
    fixture = Path("tests/golden/fixtures/blink_test_01/project.yaml")
    expected = Path("tests/golden/expected/blink_test_01")
    out_dir = tmp_path / "gen"

    pipeline = FullBuildPipeline(templates_dir=templates)
    result = pipeline.run(BuildRequest(project_file=str(fixture), out_dir=str(out_dir)))

    assert result.ok

    assert _read(out_dir / "rtl" / "soc_top.sv") == _read(expected / "rtl" / "soc_top.sv")
    assert _read(out_dir / "hal" / "board.tcl") == _read(expected / "hal" / "board.tcl")
```

---

# 11. Pytest config

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

# 12. Repo skeleton

Odporúčaná štruktúra po všetkých týchto krokoch:

```text
socfw/
  __init__.py

  build/
  builders/
  cli/
  config/
  core/
  elaborate/
  emit/
  ir/
  model/
  plugins/
    bootstrap.py
    registry.py
    bus_api.py
    simple_bus/
      planner.py
      cpu_endpoint.py
      ram_endpoint.py
  reports/
  tools/
  validate/
  templates/

src/
  ip/
    bus/
      simple_bus_fabric.sv
    irq/
      irq_combiner.sv

tests/
  unit/
  integration/
  golden/
```

---

# 13. Čo týmto získavaš

Týmto už máš:

* **modulárny plugin registry**
* **čistý CLI entrypoint**
* **test strategy**
* **repo layout**, ktoré je pripravené na reálny vývoj

A to je presne to, čo z architektúrneho návrhu robí framework, na ktorom sa dá tímovo pracovať.

---

# 14. Môj stručný verdikt

Po všetkých krokoch, ktoré sme prešli, máš už návrh frameworku, ktorý je:

* vrstvený,
* rozšíriteľný,
* pripravený na nové bus-y a IP typy,
* s jednotným YAML frontendom,
* s typed modelmi,
* s validáciou,
* s reportingom,
* s testovacou stratégiou.

To je už veľmi blízko stavu, kde sa oplatí prestať len navrhovať a začať:

1. založiť čisté repo,
2. implementovať minimal vertical slice end-to-end,
3. doplniť golden fixtures podľa tvojich troch projektov.

Najpraktickejší ďalší krok už nie je ďalšia architektúra, ale **zostavenie jedného minimálneho end-to-end branchu z týchto súborov a postupné oživovanie na reálnych fixture configoch**.
