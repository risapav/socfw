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
