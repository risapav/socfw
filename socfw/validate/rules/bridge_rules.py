from __future__ import annotations

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.validate.rules.base import ValidationRule


class MissingBridgeRule(ValidationRule):
    def __init__(self, registry) -> None:
        self.registry = registry

    def validate(self, system) -> list[Diagnostic]:
        diags: list[Diagnostic] = []

        for mod in system.project.modules:
            if mod.bus is None:
                continue

            fabric = system.project.fabric_by_name(mod.bus.fabric)
            if fabric is None:
                continue

            ip = system.ip_catalog.get(mod.type_name)
            if ip is None:
                continue

            iface = ip.bus_interface(role="slave")
            if iface is None:
                continue

            if iface.protocol == fabric.protocol:
                continue

            bridge = self.registry.find_bridge(
                src_protocol=fabric.protocol,
                dst_protocol=iface.protocol,
            )
            if bridge is None:
                diags.append(
                    Diagnostic(
                        code="BRG001",
                        severity=Severity.ERROR,
                        message=(
                            f"No bridge registered for fabric protocol '{fabric.protocol}' "
                            f"to peripheral protocol '{iface.protocol}' "
                            f"for instance '{mod.instance}'"
                        ),
                        subject="project.modules.bus",
                    )
                )

        return diags
