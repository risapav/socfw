from __future__ import annotations

from pathlib import Path

from socfw.build.context import BuildContext, BuildRequest
from socfw.build.pipeline import BuildPipeline, BuildResult
from socfw.builders.boot_image_builder import BootImageBuilder
from socfw.config.system_loader import SystemLoader
from socfw.emit.run_emitters import EmitterSuite
from socfw.reports.run_reports import ReportSuite
from socfw.tools.bin2hex_runner import Bin2HexRunner


class FullBuildPipeline:
    def __init__(self, templates_dir: str | None = None) -> None:
        if templates_dir is None:
            templates_dir = str(Path(__file__).resolve().parents[1] / "templates")
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

        report_paths = self.reports.emit_all(
            system=system,
            design=result.design,
            result=result,
            out_dir=request.out_dir,
        )
        for p in report_paths:
            result.manifest.add("report", p, "ReportSuite")

        return result
