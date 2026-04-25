from __future__ import annotations

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.model.system import SystemModel
from .base import ValidationRule


class DuplicateModuleInstanceRule(ValidationRule):
    def validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []
        seen: set[str] = set()

        for mod in system.project.modules:
            if mod.instance in seen:
                diags.append(
                    Diagnostic(
                        code="PRJ001",
                        severity=Severity.ERROR,
                        message=f"Duplicate module instance '{mod.instance}'",
                        subject="project.modules",
                    )
                )
            seen.add(mod.instance)

        return diags


class UnknownIpTypeRule(ValidationRule):
    def validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []

        for mod in system.project.modules:
            if mod.type_name not in system.ip_catalog:
                diags.append(
                    Diagnostic(
                        code="PRJ002",
                        severity=Severity.ERROR,
                        message=f"Unknown IP type '{mod.type_name}' for instance '{mod.instance}'",
                        subject="project.modules",
                    )
                )

        return diags


class UnknownGeneratedClockSourceRule(ValidationRule):
    def validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []

        for req in system.project.generated_clocks:
            inst = system.project.module_by_name(req.source_instance)
            if inst is None:
                diags.append(
                    Diagnostic(
                        code="CLK001",
                        severity=Severity.ERROR,
                        message=f"Generated clock '{req.domain}' references unknown instance '{req.source_instance}'",
                        subject="project.clocks.generated",
                    )
                )
                continue

            ip = system.ip_catalog.get(inst.type_name)
            if ip is None:
                continue

            out = ip.clocking.find_output(req.source_output)
            if out is None:
                diags.append(
                    Diagnostic(
                        code="CLK002",
                        severity=Severity.ERROR,
                        message=(
                            f"Generated clock '{req.domain}' references unknown output "
                            f"'{req.source_output}' on IP '{inst.type_name}'"
                        ),
                        subject="project.clocks.generated",
                        hints=(
                            f"Module instance `{req.source_instance}` has type `{inst.type_name}`.",
                            f"IP descriptor `{inst.type_name}` must declare this clock output:",
                            "clocking:",
                            "  outputs:",
                            f"    - name: {req.source_output}",
                            "      frequency_hz: <Hz>",
                            "If your descriptor uses `interfaces: type: clock_output`, convert it to `clocking.outputs` or enable IP alias normalization.",
                        ),
                    )
                )
                continue

            if out.kind != "generated_clock":
                diags.append(
                    Diagnostic(
                        code="CLK003",
                        severity=Severity.ERROR,
                        message=(
                            f"Output '{req.source_output}' on IP '{inst.type_name}' "
                            f"is '{out.kind}', not a generated_clock"
                        ),
                        subject="project.clocks.generated",
                    )
                )

        return diags
