from __future__ import annotations

from pathlib import Path

from socfw.build.context import BuildContext, BuildRequest
from socfw.build.pipeline import BuildPipeline, BuildResult
from dataclasses import replace

from socfw.builders.boot_image_builder import BootImageBuilder
from socfw.builders.files_ir_builder import FilesIRBuilder
from socfw.config.system_loader import SystemLoader
from socfw.core.result import Result
from socfw.emit.orchestrator import EmitOrchestrator
from socfw.model.image import BootImage
from socfw.plugins.bootstrap import create_builtin_registry
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

    def validate(self, project_file: str) -> Result:
        from socfw.validate.rules.cpu_rules import UnknownCpuTypeRule
        from socfw.validate.rules.ip_rules import UnknownIpTypeRule
        from socfw.validate.rules.project_rules import DuplicateModuleInstanceRule
        from socfw.validate.runner import ValidationRunner

        loaded = self.loader.load(project_file)
        if loaded.ok and loaded.value is not None:
            runner = ValidationRunner(rules=[
                DuplicateModuleInstanceRule(),
                UnknownCpuTypeRule(),
                UnknownIpTypeRule(),
            ])
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

        return result
