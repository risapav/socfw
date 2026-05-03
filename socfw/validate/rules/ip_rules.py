from __future__ import annotations

from socfw.core.diag_builders import err
from socfw.core.diagnostics import Diagnostic, Severity, SourceLocation
from socfw.model.ip_graph import transitive_requires
from socfw.validate.rules.base import ValidationRule


class UnknownIpTypeRule(ValidationRule):
    def validate(self, system) -> list:
        diags = []
        known = ", ".join(sorted(system.ip_catalog.keys())) or "none"

        for idx, mod in enumerate(system.project.modules):
            if mod.type_name not in system.ip_catalog:
                diags.append(
                    err(
                        "IP001",
                        f"Unknown IP type '{mod.type_name}' for instance '{mod.instance}'",
                        "project.modules",
                        file=system.sources.project_file,
                        path=f"modules[{idx}].type",
                        hints=[
                            f"Project module `{mod.instance}` uses `type: {mod.type_name}`.",
                            "That value must match `ip.name` in one loaded *.ip.yaml descriptor.",
                            "Check `registries.ip` paths in project.yaml.",
                            "Check `registries.packs` if the IP should come from a pack.",
                            f"Known IP descriptors: {known}",
                            "Run `socfw doctor project.yaml` to inspect loaded IP catalog.",
                        ],
                    )
                )

        return diags


class UnknownIpParamRule(ValidationRule):
    """Warn when a project module passes a param not declared in the IP descriptor."""

    def validate(self, system) -> list[Diagnostic]:
        diags: list[Diagnostic] = []

        for mod in system.project.modules:
            ip = system.ip_catalog.get(mod.type_name)
            if ip is None or not ip.declared_params:
                continue

            declared = {p.name for p in ip.declared_params}
            for param_name in mod.params:
                if param_name not in declared:
                    diags.append(
                        Diagnostic(
                            code="IP002",
                            severity=Severity.WARNING,
                            message=(
                                f"Instance '{mod.instance}' passes unknown param '{param_name}' "
                                f"to IP '{mod.type_name}'"
                            ),
                            subject="project.modules",
                            spans=(SourceLocation(file=system.sources.project_file),),
                            hints=(
                                f"IP '{mod.type_name}' declares: {', '.join(sorted(declared))}",
                                f"Remove or rename '{param_name}' in the project params block.",
                            ),
                        )
                    )

        return diags


class MissingClockPortBindingRule(ValidationRule):
    """Error when IP declares additional_input_ports not covered by module clocks: dict.

    A missing clock binding silently wires the port to 1'b0, which causes the
    module to receive a dead clock — a silent correctness bug.
    """

    def validate(self, system) -> list[Diagnostic]:
        diags: list[Diagnostic] = []

        for mod in system.project.modules:
            ip = system.ip_catalog.get(mod.type_name)
            if ip is None or not ip.clocking:
                continue

            all_clock_ports = list(ip.clocking.additional_input_ports)
            if ip.clocking.primary_input_port:
                all_clock_ports = [ip.clocking.primary_input_port] + all_clock_ports

            bound_ports = {cb.port_name for cb in mod.clocks}

            for port in all_clock_ports:
                if port not in bound_ports:
                    domains = [system.project.primary_clock_domain]
                    if system.timing:
                        domains += [c.name for c in system.timing.generated_clocks]
                    domain_hint = ", ".join(domains)

                    diags.append(
                        Diagnostic(
                            code="IP003",
                            severity=Severity.ERROR,
                            message=(
                                f"Instance '{mod.instance}' (type '{mod.type_name}') "
                                f"has unbound clock port '{port}'"
                            ),
                            subject="project.modules",
                            spans=(SourceLocation(file=system.sources.project_file),),
                            hints=(
                                f"Add '{port}: <domain>' under `clocks:` for instance '{mod.instance}'.",
                                "Without this binding the port receives 1'b0 (dead clock).",
                                f"Available clock domains: {domain_hint}",
                            ),
                        )
                    )

        return diags


class UnknownIpRequiresRule(ValidationRule):
    """Error when a used IP's requires: list names an IP absent from the catalog.

    Only checks IPs that are transitively required by project modules — unused
    IPs in the catalog are ignored.
    """

    def validate(self, system) -> list[Diagnostic]:
        diags: list[Diagnostic] = []
        catalog = system.ip_catalog

        # Collect all IPs reachable from the project modules
        reachable: set[str] = {m.type_name for m in system.project.modules}
        for type_name in list(reachable):
            ip = catalog.get(type_name)
            if ip is not None:
                reachable |= transitive_requires(ip, catalog)

        for ip_name in sorted(reachable):
            ip = catalog.get(ip_name)
            if ip is None:
                continue
            for dep_name in ip.requires:
                if dep_name not in catalog:
                    diags.append(
                        Diagnostic(
                            code="IP004",
                            severity=Severity.ERROR,
                            message=(
                                f"IP '{ip.name}' requires '{dep_name}' "
                                f"which is not in the catalog"
                            ),
                            subject="ip.requires",
                            spans=(SourceLocation(file=ip.source_file),) if ip.source_file else (),
                            hints=(
                                f"Add an IP registry path containing '{dep_name}.ip.yaml' "
                                f"to registries.ip in project.yaml.",
                                f"Or remove the requires entry from '{ip.name}' if the dependency "
                                f"is already included via artifacts.synthesis.",
                            ),
                        )
                    )

        return diags
