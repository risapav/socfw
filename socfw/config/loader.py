from __future__ import annotations
from pathlib import Path
from typing import Any

import yaml

from socfw.core.result import Result
from socfw.core.diagnostics import Diagnostic, Severity, SourceLocation
from socfw.config.raw_models import RawConfigBundle, RawDocument
from socfw.config.schema.project import ProjectV2


class ConfigMigrator:
    def migrate_v1_to_v2(self, legacy: dict[str, Any]) -> dict[str, Any]:
        raise NotImplementedError("v1→v2 migration not yet implemented")


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

        version = data.get("version")
        if version not in (2,):
            return Result(
                diagnostics=[
                    Diagnostic(
                        code="CFG003",
                        severity=Severity.ERROR,
                        message=f"Unsupported config version: {version!r}. Expected version: 2",
                        subject="project config",
                        locations=(SourceLocation(file=project_file),),
                    )
                ]
            )

        try:
            ProjectV2.model_validate(data)
        except Exception as e:
            return Result(
                diagnostics=[
                    Diagnostic(
                        code="CFG004",
                        severity=Severity.ERROR,
                        message=f"Schema validation failed: {e}",
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
