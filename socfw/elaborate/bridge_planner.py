from __future__ import annotations

from pathlib import Path

from socfw.elaborate.bridge_plan import PlannedBridge
from socfw.elaborate.bridge_registry import BridgeRegistry

_BRIDGES_DIR = Path(__file__).resolve().parents[1] / "bridges"


class BridgePlanner:
    def __init__(self, registry: BridgeRegistry | None = None) -> None:
        self.registry = registry or BridgeRegistry()

    def plan(self, system) -> list[PlannedBridge]:
        bridges: list[PlannedBridge] = []

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

            if fabric.protocol == iface.protocol:
                continue

            support = self.registry.find_bridge(
                src_protocol=fabric.protocol,
                dst_protocol=iface.protocol,
            )
            if support is None:
                continue

            rtl_file = _BRIDGES_DIR / f"{support.bridge_kind}_bridge.sv"

            bridges.append(
                PlannedBridge(
                    instance=f"u_bridge_{mod.instance}",
                    kind=support.bridge_kind,
                    src_protocol=fabric.protocol,
                    dst_protocol=iface.protocol,
                    target_module=mod.instance,
                    fabric=fabric.name,
                    rtl_file=str(rtl_file),
                )
            )

        return sorted(bridges, key=lambda b: b.instance)
