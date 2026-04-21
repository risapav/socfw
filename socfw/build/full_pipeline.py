from __future__ import annotations

from pathlib import Path

from socfw.build.context import BuildContext, BuildRequest
from socfw.build.pipeline import BuildPipeline, BuildResult
from socfw.config.system_loader import SystemLoader
from socfw.emit.run_emitters import EmitterSuite


class FullBuildPipeline:
    def __init__(self, templates_dir: str | None = None) -> None:
        if templates_dir is None:
            templates_dir = str(Path(__file__).resolve().parents[1] / "templates")
        self.loader = SystemLoader()
        self.pipeline = BuildPipeline()
        self.emitters = EmitterSuite(templates_dir)

    def run(self, request: BuildRequest) -> BuildResult:
        loaded = self.loader.load(request.project_file)
        if not loaded.ok or loaded.value is None:
            return BuildResult(ok=False, diagnostics=loaded.diagnostics)

        result = self.pipeline.run(request, loaded.value)
        result.diagnostics = loaded.diagnostics + result.diagnostics

        if not result.ok:
            return result

        ctx = BuildContext(out_dir=Path(request.out_dir))
        manifest = self.emitters.emit_all(
            ctx,
            board_ir=result.board_ir,
            timing_ir=result.timing_ir,
            rtl_ir=result.rtl_ir,
        )
        result.manifest = manifest
        return result
