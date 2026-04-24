from __future__ import annotations

from pathlib import Path

from socfw.build.pipeline import BuildResult
from socfw.core.diagnostics import Diagnostic, Severity


class LegacyBackend:
    def build(self, *, system, request) -> BuildResult:
        out_dir = Path(request.out_dir)
        out_dir.mkdir(parents=True, exist_ok=True)

        try:
            from legacy_build import build_legacy

            build_legacy(
                project_file=request.project_file,
                out_dir=str(out_dir),
            )
            return BuildResult(ok=True)
        except Exception as exc:
            return BuildResult(
                ok=False,
                diagnostics=[
                    Diagnostic(
                        code="BLD100",
                        severity=Severity.ERROR,
                        message=f"Legacy backend build failed: {exc}",
                        subject="build",
                    )
                ],
            )
