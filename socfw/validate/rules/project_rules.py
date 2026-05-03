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
                            f"Fix in {inst.type_name}.ip.yaml:",
                            "clocking:",
                            "  outputs:",
                            f"    - port: {req.source_output}",
                            "      kind: generated_clock",
                            f"      domain: {req.domain}",
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


class ResetDriverRule(ValidationRule):
    """Validate the reset_driver field: instance exists, port is a 1-bit output."""

    def validate(self, system: SystemModel) -> list[Diagnostic]:
        reset_driver = getattr(system.project, "reset_driver", None)
        if not reset_driver:
            return []

        parts = reset_driver.split(".", 1)
        if len(parts) != 2 or not parts[0] or not parts[1]:
            return [
                Diagnostic(
                    code="RST010",
                    severity=Severity.ERROR,
                    message=f"reset_driver '{reset_driver}' must be in 'instance.port' format",
                    subject="project.reset_driver",
                )
            ]

        inst_name, port_name = parts
        mod = system.project.module_by_name(inst_name)
        if mod is None:
            return [
                Diagnostic(
                    code="RST011",
                    severity=Severity.ERROR,
                    message=f"reset_driver references unknown instance '{inst_name}'",
                    subject="project.reset_driver",
                    hints=(f"Add an instance named '{inst_name}' to modules:",),
                )
            ]

        ip = system.ip_catalog.get(mod.type_name)
        if ip is None:
            return []

        port = next((p for p in (ip.ports or []) if p.name == port_name), None)
        if port is None:
            return [
                Diagnostic(
                    code="RST012",
                    severity=Severity.ERROR,
                    message=(
                        f"reset_driver references unknown port '{port_name}' "
                        f"on instance '{inst_name}' (type '{mod.type_name}')"
                    ),
                    subject="project.reset_driver",
                )
            ]

        diags: list[Diagnostic] = []
        if port.direction != "output":
            diags.append(
                Diagnostic(
                    code="RST013",
                    severity=Severity.ERROR,
                    message=(
                        f"reset_driver port '{inst_name}.{port_name}' "
                        f"is '{port.direction}', must be 'output'"
                    ),
                    subject="project.reset_driver",
                )
            )
        if getattr(port, "width", 1) != 1:
            diags.append(
                Diagnostic(
                    code="RST014",
                    severity=Severity.ERROR,
                    message=(
                        f"reset_driver port '{inst_name}.{port_name}' "
                        f"has width {port.width}, must be 1"
                    ),
                    subject="project.reset_driver",
                )
            )
        return diags


class ModuleResetOverrideRule(ValidationRule):
    """Warn when a module reset expression will be silently ignored."""

    def validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []

        for mod in system.project.modules:
            reset_override = getattr(mod, "reset_override", "auto")
            if reset_override == "auto" or reset_override is None:
                continue

            ip = system.ip_catalog.get(mod.type_name)
            if ip is None:
                continue

            if not ip.reset.port:
                diags.append(
                    Diagnostic(
                        code="RST020",
                        severity=Severity.WARNING,
                        message=(
                            f"Module '{mod.instance}' has reset: '{reset_override}' "
                            f"but IP '{mod.type_name}' declares no reset port — "
                            "the expression will be ignored"
                        ),
                        subject=f"project.modules.{mod.instance}",
                        hints=(
                            f"Add 'reset: {{port: <port_name>}}' to {mod.type_name}.ip.yaml,",
                            "or remove the reset: override from project.yaml.",
                        ),
                    )
                )

        return diags


class TimingResetUnusedRule(ValidationRule):
    """Warn when a board reset is declared but no instantiated IP consumes it."""

    def validate(self, system: SystemModel) -> list[Diagnostic]:
        if system.board.sys_reset is None:
            return []

        for mod in system.project.modules:
            ip = system.ip_catalog.get(mod.type_name)
            if ip is not None and ip.reset.port:
                return []

        return [
            Diagnostic(
                code="RST001",
                severity=Severity.WARNING,
                message=(
                    f"Board reset '{system.board.sys_reset.top_name}' is declared "
                    "but no instantiated IP consumes reset"
                ),
                subject="project.modules",
                hints=(
                    "Add 'reset: {port: rst_ni, active_high: false}' to the IP descriptor,",
                    "or remove the reset pin from the timing config.",
                ),
            )
        ]


class TimingIoDelayMinMissingRule(ValidationRule):
    """Warn when IO max delay is set but min delay is not specified."""

    def validate(self, system: SystemModel) -> list[Diagnostic]:
        timing = system.timing
        if timing is None or not timing.io_auto:
            return []

        diags: list[Diagnostic] = []

        if timing.io_default_input_max_ns is not None and timing.io_default_input_min_ns is None:
            diags.append(
                Diagnostic(
                    code="TIM201",
                    severity=Severity.WARNING,
                    message="Input max IO delay is set but input min IO delay is missing",
                    subject="timing.io_delays",
                    hints=("Add 'default_input_min_ns' to the io_delays section.",),
                )
            )

        if timing.io_default_output_max_ns is not None and timing.io_default_output_min_ns is None:
            diags.append(
                Diagnostic(
                    code="TIM201",
                    severity=Severity.WARNING,
                    message="Output max IO delay is set but output min IO delay is missing",
                    subject="timing.io_delays",
                    hints=("Add 'default_output_min_ns' to the io_delays section.",),
                )
            )

        return diags


class SyncFromUnknownDomainRule(ValidationRule):
    """Error when reset.sync_from references a domain not declared in the project."""

    def validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []

        known = {system.project.primary_clock_domain}
        known |= {g.domain for g in system.project.generated_clocks}

        for req in system.project.generated_clocks:
            if req.sync_from and req.sync_from not in known:
                diags.append(
                    Diagnostic(
                        code="CLK010",
                        severity=Severity.ERROR,
                        message=(
                            f"Generated clock '{req.domain}' reset.sync_from "
                            f"references unknown domain '{req.sync_from}'"
                        ),
                        subject="project.clocks.generated",
                        hints=(
                            f"Known domains: {', '.join(sorted(known))}",
                            f"Fix reset.sync_from under the '{req.domain}' clock entry.",
                        ),
                    )
                )

        return diags


class GeneratedClockMissingResetSyncRule(ValidationRule):
    """Warn when a generated clock has CDC to the primary domain but no reset sync declared.

    If at least one module runs on the primary domain AND at least one runs on
    this generated domain, there is a potential CDC reset path that should be
    explicitly handled (either sync_from or no_reset: true).
    """

    def validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []

        # Collect which domains are actually used by instantiated modules
        used_domains: set[str] = set()
        for mod in system.project.modules:
            for cb in mod.clocks:
                used_domains.add(cb.domain)

        primary = system.project.primary_clock_domain
        if primary not in used_domains:
            return []

        for req in system.project.generated_clocks:
            if req.domain not in used_domains:
                continue
            if req.sync_from or req.no_reset:
                continue

            diags.append(
                Diagnostic(
                    code="CLK011",
                    severity=Severity.WARNING,
                    message=(
                        f"Generated clock '{req.domain}' has modules clocked by it "
                        f"and by the primary domain '{primary}', "
                        f"but no reset synchronization is declared"
                    ),
                    subject="project.clocks.generated",
                    hints=(
                        f"Add 'reset: {{sync_from: {primary}, sync_stages: 2}}' "
                        f"under the '{req.domain}' clock entry to declare CDC reset sync.",
                        "Or add 'reset: {none: true}' if the domain needs no reset.",
                        "Without this, the reset crossing is undocumented and may be "
                        "incorrectly timed.",
                    ),
                )
            )

        return diags
