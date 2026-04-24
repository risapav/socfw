from __future__ import annotations

from pathlib import Path

from socfw.utils.deprecation import print_legacy_warning


def _collect_generated(out_dir: str) -> list[str]:
    root = Path(out_dir)
    found = []
    for sub in ["rtl", "hal", "timing", "sw", "docs", "reports"]:
        sp = root / sub
        if sp.exists():
            for fp in sorted(sp.rglob("*")):
                if fp.is_file():
                    found.append(str(fp))
    return found


def build_legacy(project_file: str, out_dir: str) -> list[str]:
    print_legacy_warning()
    from pathlib import Path as _Path

    from socfw.build.context import BuildRequest
    from socfw.build.full_pipeline import FullBuildPipeline

    templates_dir = str(_Path(__file__).resolve().parent / "socfw" / "templates")
    pipeline = FullBuildPipeline(templates_dir=templates_dir)
    result = pipeline.run(BuildRequest(project_file=project_file, out_dir=out_dir))

    if not result.ok:
        from socfw.core.diagnostics import Severity
        errors = [d.message for d in result.diagnostics if d.severity == Severity.ERROR]
        raise RuntimeError("Legacy build failed:\n" + "\n".join(errors))

    return _collect_generated(out_dir)
