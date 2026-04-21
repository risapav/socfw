from __future__ import annotations
from pathlib import Path

import yaml

from socfw.core.result import Result
from socfw.core.diagnostics import Diagnostic, Severity, SourceLocation
from socfw.config.raw_models import RawConfigBundle, RawDocument


class ConfigLoader:
    def load(self, project_file: str) -> Result[RawConfigBundle]:
        diags: list[Diagnostic] = []
        bundle = RawConfigBundle()

        path = Path(project_file)
        if not path.exists():
            return Result(
                diagnostics=[
                    Diagnostic(
                        code="CFG001",
                        severity=Severity.ERROR,
                        message=f"Project file not found: {project_file}",
                        subject="project config",
                        locations=(SourceLocation(file=project_file),),
                    )
                ]
            )

        try:
            with path.open("r", encoding="utf-8") as f:
                data = yaml.safe_load(f) or {}
        except Exception as e:
            return Result(
                diagnostics=[
                    Diagnostic(
                        code="CFG002",
                        severity=Severity.ERROR,
                        message=f"Failed to parse YAML: {e}",
                        subject="project config",
                        locations=(SourceLocation(file=project_file),),
                    )
                ]
            )

        bundle.project = RawDocument(
            kind="project",
            data=data,
            source_file=str(path),
        )
        return Result(value=bundle, diagnostics=diags)
