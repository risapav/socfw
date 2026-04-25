from __future__ import annotations

from pathlib import Path

from socfw.build.context import BuildContext, BuildRequest
from socfw.build.pipeline import BuildPipeline, BuildResult
from dataclasses import replace

from socfw.builders.boot_image_builder import BootImageBuilder
from socfw.builders.files_ir_builder import FilesIRBuilder
from socfw.builders.rtl_ir_builder import RtlIrBuilder
from socfw.builders.vendor_artifact_collector import VendorArtifactCollector
from socfw.build.provenance import SocBuildProvenance
from socfw.config.system_loader import SystemLoader
from socfw.elaborate.bridge_planner import BridgePlanner
from socfw.emit.rtl_emitter import RtlEmitter
from socfw.emit.files_tcl_emitter import FilesTclEmitter
from socfw.emit.sdc_emitter import SdcEmitter
from socfw.core.result import Result
from socfw.emit.orchestrator import EmitOrchestrator
from socfw.model.image import BootImage
from socfw.plugins.bootstrap import create_builtin_registry
from socfw.reports.build_summary import BuildSummaryReport
from socfw.reports.orchestrator import ReportOrchestrator
from socfw.tools.bin2hex_runner import Bin2HexRunner
from socfw.tools.firmware_builder import FirmwareBuilder


class FullBuildPipeline:
    def __init__(self, templates_dir: str | None = None) -> None:
        if templates_dir is None:
            templates_dir = str(Path(__file__).resolve().parents[1] / "templates")
        self.registry = create_builtin_registry(templates_dir)
        self.loader = SystemLoader()
        self.pipeline = BuildPipeline(self.registry)
        self.emitters = EmitOrchestrator(self.registry)
        self.reports = ReportOrchestrator(self.registry)
        self.image_builder = BootImageBuilder()
        self.bin2hex = Bin2HexRunner()
        self.firmware_builder = FirmwareBuilder()
        self.files_ir_builder = FilesIRBuilder()
        self.vendor_collector = VendorArtifactCollector()
        self.build_summary = BuildSummaryReport()
        self.bridge_planner = BridgePlanner()
        self.rtl_ir_builder = RtlIrBuilder()
        self.rtl_native_emitter = RtlEmitter()
        self.files_tcl_emitter = FilesTclEmitter()
        self.sdc_emitter = SdcEmitter()

    def validate(self, project_file: str) -> Result:
        from socfw.validate.runner import ValidationRunner

        loaded = self.loader.load(project_file)
        if loaded.ok and loaded.value is not None:
            runner = ValidationRunner(rules=list(self.registry.validators))
            loaded.extend(runner.run(loaded.value))
        return loaded

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
        files_ir = (
            self.files_ir_builder.build(result.design, result.rtl_ir)
            if result.design is not None and result.rtl_ir is not None
            else None
        )
        manifest = self.emitters.emit_all(
            ctx,
            board_ir=result.board_ir,
            timing_ir=result.timing_ir,
            rtl_ir=result.rtl_ir,
            files_ir=files_ir,
            software_ir=result.software_ir,
            docs_ir=result.docs_ir,
            register_block_irs=result.register_block_irs,
            peripheral_shell_irs=result.peripheral_shell_irs,
        )
        result.manifest = manifest

        fw_res = self.firmware_builder.build(system, request.out_dir)
        result.diagnostics.extend(fw_res.diagnostics)
        if fw_res.ok and fw_res.value is not None and system.ram is not None:
            fw_boot = BootImage(
                input_file=fw_res.value.bin,
                output_file=fw_res.value.hex,
                input_format="bin",
                output_format="hex",
                size_bytes=system.ram.size,
                endian="little",
            )
            conv = self.bin2hex.run(fw_boot)
            result.diagnostics.extend(conv.diagnostics)
            if conv.ok and conv.value is not None:
                system.ram = replace(system.ram, init_file=conv.value, image_format="hex")

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

        bridge_summary = _write_bridge_summary(system, request.out_dir)
        if bridge_summary is not None:
            result.manifest.add("report", bridge_summary, "BridgeSummary")

        planned_bridges = self.bridge_planner.plan(system)
        bridge_files = _copy_bridge_artifacts(request.out_dir, planned_bridges)
        for bf in bridge_files:
            result.manifest.add("rtl", bf, "BridgePlanner")

        rtl_top = self.rtl_ir_builder.build(
            system=system,
            planned_bridges=planned_bridges,
            design=result.design,
        )
        native_top_file = self.rtl_native_emitter.emit_top(request.out_dir, rtl_top)
        result.manifest.add("rtl", native_top_file, "RtlNativeEmitter")

        files_tcl = self.files_tcl_emitter.emit(
            out_dir=request.out_dir,
            system=system,
            planned_bridges=planned_bridges,
        )
        result.manifest.add("hal", files_tcl, "FilesTclEmitter")

        sdc_file = self.sdc_emitter.emit(out_dir=request.out_dir, system=system)
        result.manifest.add("timing", sdc_file, "SdcEmitter")

        soc_provenance = _build_soc_provenance(system, result, request.out_dir, planned_bridges)
        summary_path = self.build_summary.write(request.out_dir, soc_provenance)
        result.manifest.add("report", summary_path, "BuildSummary")

        return result


def _copy_bridge_artifacts(out_dir: str, planned_bridges) -> list[str]:
    if not planned_bridges:
        return []
    rtl_dir = Path(out_dir) / "rtl"
    rtl_dir.mkdir(parents=True, exist_ok=True)
    copied = []
    for bridge in planned_bridges:
        src = Path(bridge.rtl_file)
        dst = rtl_dir / src.name
        dst.write_text(src.read_text(encoding="utf-8"), encoding="utf-8")
        copied.append(str(dst))
    return sorted(dict.fromkeys(copied))


def _collect_bridge_pairs(system) -> list[tuple[str, str, str]]:
    pairs = []
    for mod in system.project.modules:
        if mod.bus is None:
            continue
        fabric = system.project.fabric_by_name(mod.bus.fabric)
        if fabric is None:
            continue
        ip = system.ip_catalog.get(mod.type_name)
        if ip is None:
            continue
        iface = ip.bus_interface(role="slave")
        if iface is None:
            continue
        if fabric.protocol != iface.protocol:
            pairs.append((fabric.protocol, iface.protocol, mod.instance))
    return sorted(pairs, key=lambda x: (x[2], x[0], x[1]))


def _build_soc_provenance(system, result: BuildResult, out_dir: str, planned_bridges=None) -> SocBuildProvenance:
    cpu_desc = system.cpu_desc()
    vendor_bundle = VendorArtifactCollector().collect(result.design) if result.design is not None else None

    if planned_bridges:
        bridge_pairs = sorted(
            f"{b.target_module}: {b.src_protocol} -> {b.dst_protocol}"
            for b in planned_bridges
        )
    else:
        bridge_pairs = [
            f"{inst}: {src} -> {dst}"
            for src, dst, inst in _collect_bridge_pairs(system)
        ]

    out_root = Path(out_dir).resolve()

    def _rel(abs_path: str) -> str:
        try:
            return str(Path(abs_path).resolve().relative_to(out_root))
        except ValueError:
            return Path(abs_path).name

    generated = sorted(
        _rel(a.path) for a in result.manifest.artifacts
    ) if result.manifest is not None else []

    vendor_qip = sorted(Path(p).name for p in (vendor_bundle.qip_files if vendor_bundle else []))
    vendor_sdc = sorted(Path(p).name for p in (vendor_bundle.sdc_files if vendor_bundle else []))

    return SocBuildProvenance(
        project_name=system.project.name,
        project_mode=system.project.mode,
        board_id=system.board.board_id,
        cpu_type=system.cpu.type_name if system.cpu is not None else None,
        cpu_module=cpu_desc.module if cpu_desc is not None else None,
        ip_types=sorted({m.type_name for m in system.project.modules}),
        module_instances=sorted(m.instance for m in system.project.modules),
        timing_generated_clocks=len(system.timing.generated_clocks) if system.timing is not None else 0,
        timing_false_paths=len(system.timing.false_paths) if system.timing is not None else 0,
        vendor_qip_files=vendor_qip,
        vendor_sdc_files=vendor_sdc,
        bridge_pairs=bridge_pairs,
        generated_files=generated,
        aliases_used=list(system.sources.aliases_used),
    )


def _write_bridge_summary(system, out_dir: str) -> str | None:
    pairs = _collect_bridge_pairs(system)
    if not pairs:
        return None

    reports_dir = Path(out_dir) / "reports"
    reports_dir.mkdir(parents=True, exist_ok=True)
    fp = reports_dir / "bridge_summary.txt"
    lines = [f"{inst}: {src} -> {dst}" for src, dst, inst in pairs]
    fp.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return str(fp)
