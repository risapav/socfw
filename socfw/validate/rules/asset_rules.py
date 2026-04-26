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


class IpArtifactExistsRule(ValidationRule):
    """Check that all declared synthesis artifacts actually exist on disk."""

    def validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []

        used_types = {m.type_name for m in system.project.modules}
        for type_name in sorted(used_types):
            ip = system.ip_catalog.get(type_name)
            if ip is None:
                continue
            for path in ip.artifacts.synthesis:
                if not Path(path).exists():
                    diags.append(
                        Diagnostic(
                            code="IP101",
                            severity=Severity.WARNING,
                            message=f"Missing IP artifact file: {path}",
                            subject="ip.artifacts.synthesis",
                            hints=(
                                f"Declared in IP descriptor for '{ip.name}'.",
                                "Generate the IP core or update the artifacts list.",
                            ),
                        )
                    )

        return diags
