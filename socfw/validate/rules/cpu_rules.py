from __future__ import annotations

from socfw.core.diag_builders import err
from socfw.core.diagnostics import Diagnostic, Severity, SuggestedFix
from socfw.validate.rules.base import ValidationRule


class UnknownCpuTypeRule(ValidationRule):
    def validate(self, system) -> list:
        if system.cpu is None:
            return []

        if system.cpu.type_name not in system.cpu_catalog:
            known = ", ".join(sorted(system.cpu_catalog.keys())) or "none"
            return [
                err(
                    "CPU001",
                    f"Unknown CPU type '{system.cpu.type_name}'",
                    "project.cpu",
                    file=system.sources.project_file,
                    path="cpu.type",
                    category="cpu",
                    hints=[
                        "Add a matching *.cpu.yaml descriptor to a registered catalog path.",
                        "Or change project.cpu.type to an existing CPU descriptor.",
                    ],
                    fixes=[
                        SuggestedFix(message="Change to an existing CPU descriptor name")
                    ],
                    detail=f"Known CPU descriptors: {known}",
                )
            ]
        return []


class UnknownCpuFabricRule(ValidationRule):
    def validate(self, system) -> list[Diagnostic]:
        if system.cpu is None:
            return []

        if system.project.fabric_by_name(system.cpu.fabric) is None:
            return [
                Diagnostic(
                    code="CPU002",
                    severity=Severity.ERROR,
                    message=f"CPU references unknown fabric '{system.cpu.fabric}'",
                    subject="project.cpu.fabric",
                )
            ]
        return []


class CpuDescriptorBusMissingRule(ValidationRule):
    def validate(self, system) -> list[Diagnostic]:
        if system.cpu is None:
            return []

        desc = system.cpu_desc()
        if desc is None:
            return []

        if desc.bus_master is None:
            return [
                Diagnostic(
                    code="CPU003",
                    severity=Severity.ERROR,
                    message=f"CPU '{system.cpu.type_name}' has no bus_master descriptor",
                    subject="cpu.descriptor",
                )
            ]
        return []
