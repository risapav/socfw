from __future__ import annotations

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.validate.rules.base import ValidationRule


class UnknownCpuTypeRule(ValidationRule):
    def validate(self, system) -> list[Diagnostic]:
        if system.cpu is None:
            return []

        if system.cpu.type_name not in system.cpu_catalog:
            return [
                Diagnostic(
                    code="CPU001",
                    severity=Severity.ERROR,
                    message=f"Unknown CPU type '{system.cpu.type_name}'",
                    subject="project.cpu",
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
