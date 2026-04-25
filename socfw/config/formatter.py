from __future__ import annotations

from pathlib import Path

import yaml

from socfw.config.common import load_yaml_file
from socfw.config.normalizers.project import normalize_project_document
from socfw.config.normalizers.timing import normalize_timing_document
from socfw.core.diagnostics import Diagnostic, Severity, SourceLocation
from socfw.core.result import Result


def _dump_yaml(data: dict) -> str:
    return yaml.safe_dump(
        data,
        sort_keys=False,
        allow_unicode=True,
        default_flow_style=False,
    )


class ConfigFormatter:
    def format_file(self, path: str, *, write: bool = False) -> Result[str]:
        loaded = load_yaml_file(path)
        if not loaded.ok:
            return Result(diagnostics=loaded.diagnostics)

        data = loaded.value or {}
        kind = data.get("kind")

        if kind == "project" or "project" in data or "design" in data:
            norm = normalize_project_document(data, file=path)
        elif kind == "timing" or "timing" in data or any(
            k in data for k in ("clocks", "io_delays", "false_paths")
        ):
            norm = normalize_timing_document(data, file=path)
        else:
            return Result(
                diagnostics=[
                    Diagnostic(
                        code="FMT001",
                        severity=Severity.ERROR,
                        message="Unable to infer YAML document type for formatting",
                        subject="fmt",
                        spans=(SourceLocation(file=path),),
                        hints=("Expected a project or timing YAML document.",),
                    )
                ]
            )

        text = _dump_yaml(norm.data)

        if write:
            Path(path).write_text(text, encoding="utf-8")

        return Result(value=text, diagnostics=norm.diagnostics)
