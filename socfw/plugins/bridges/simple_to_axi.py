from __future__ import annotations

from socfw.elaborate.bus_plan import PlannedBusBridge


class SimpleBusToAxiLiteBridgePlanner:
    def maybe_plan_bridge(self, *, fabric, mod, ip) -> PlannedBusBridge | None:
        iface = ip.bus_interface(role="slave")
        if iface is None:
            return None

        if fabric.protocol == "simple_bus" and iface.protocol == "axi_lite":
            return PlannedBusBridge(
                instance=f"bridge_{mod.instance}",
                module="simple_bus_to_axi_lite_bridge",
                src_protocol="simple_bus",
                dst_protocol="axi_lite",
                src_fabric=fabric.name,
                dst_instance=mod.instance,
                dst_port=iface.port_name,
            )

        return None
