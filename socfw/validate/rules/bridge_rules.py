from __future__ import annotations

from socfw.core.diag_builders import err
from socfw.core.diagnostics import SuggestedFix
from socfw.validate.rules.base import ValidationRule


class MissingBridgeRule(ValidationRule):
    def __init__(self, registry) -> None:
        self.registry = registry

    def validate(self, system) -> list:
        diags = []
        project_file = system.sources.project_file

        for idx, mod in enumerate(system.project.modules):
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
                    err(
                        "BRG001",
                        (
                            f"No bridge registered for fabric protocol '{fabric.protocol}' "
                            f"to peripheral protocol '{iface.protocol}'"
                        ),
                        "project.modules.bus",
                        file=project_file,
                        path=f"modules[{idx}].bus",
                        category="bridge",
                        hints=[
                            "Register a bridge planner plugin for this protocol pair.",
                            "Or change the peripheral bus interface protocol to match the fabric.",
                            "Or place the peripheral behind an already supported adapter.",
                        ],
                        fixes=[
                            SuggestedFix(
                                message=f"Register bridge {fabric.protocol} -> {iface.protocol}"
                            ),
                            SuggestedFix(
                                message=f"Change peripheral '{mod.instance}' interface protocol to '{fabric.protocol}'",
                                path=f"modules[{idx}]",
                            ),
                        ],
                        detail=(
                            f"Instance '{mod.instance}' is attached to fabric '{fabric.name}', "
                            f"but its IP descriptor declares slave protocol '{iface.protocol}'."
                        ),
                    )
                )
        return diags
