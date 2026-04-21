from __future__ import annotations
from pathlib import Path

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.model.system import SystemModel
from .base import ValidationRule


class VendorIpArtifactExistsRule(ValidationRule):
    def validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []

        for ip in system.ip_catalog.values():
            if ip.origin.kind != "vendor_generated":
                continue

            for path in ip.artifacts.synthesis:
                if not Path(path).exists():
                    diags.append(
                        Diagnostic(
                            code="AST001",
                            severity=Severity.WARNING,
                            message=f"Vendor IP '{ip.name}' synthesis artifact not found: {path}",
                            subject="ip.artifacts.synthesis",
                        )
                    )

        return diags
