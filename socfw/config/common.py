from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml

from socfw.core.diagnostics import Diagnostic, Severity, SourceLocation
from socfw.core.result import Result


def load_yaml_file(path: str | Path) -> Result[dict[str, Any]]:
    p = Path(path)

    if not p.exists():
        return Result(
            diagnostics=[
                Diagnostic(
                    code="CFG001",
                    severity=Severity.ERROR,
                    message=f"Configuration file not found: {p}",
                    subject="config",
                    locations=(SourceLocation(file=str(p)),),
                )
            ]
        )

    try:
        with p.open("r", encoding="utf-8") as f:
            data = yaml.safe_load(f) or {}
    except Exception as exc:
        return Result(
            diagnostics=[
                Diagnostic(
                    code="CFG002",
                    severity=Severity.ERROR,
                    message=f"Failed to parse YAML file '{p}': {exc}",
                    subject="config",
                    locations=(SourceLocation(file=str(p)),),
                )
            ]
        )

    if not isinstance(data, dict):
        return Result(
            diagnostics=[
                Diagnostic(
                    code="CFG003",
                    severity=Severity.ERROR,
                    message=f"Top-level YAML document in '{p}' must be a mapping",
                    subject="config",
                    locations=(SourceLocation(file=str(p)),),
                )
            ]
        )

    return Result(value=data)
