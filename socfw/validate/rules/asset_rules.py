from __future__ import annotations
from pathlib import Path

from socfw.core.diagnostics import Diagnostic, Severity, SourceLocation
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

            base_dir = Path(ip.source_file).parent if ip.source_file else None
            spans = (SourceLocation(file=ip.source_file),) if ip.source_file else ()

            for abs_path in ip.artifacts.synthesis:
                if Path(abs_path).exists():
                    continue

                hints = [f"Declared in IP descriptor for '{ip.name}'."]

                if base_dir is not None:
                    try:
                        rel = Path(abs_path).relative_to(base_dir.resolve())
                        hints.append(
                            f"Path '{rel}' resolved relative to '{base_dir}' — verify the path is correct."
                        )
                    except ValueError:
                        hints.append(f"Resolved absolute path: {abs_path}")

                hints.append("Generate the IP core or fix the path in the IP yaml artifacts list.")

                diags.append(
                    Diagnostic(
                        code="IP101",
                        severity=Severity.WARNING,
                        message=f"Missing IP artifact file: {abs_path}",
                        subject="ip.artifacts.synthesis",
                        hints=tuple(hints),
                        spans=spans,
                    )
                )

        return diags
