from __future__ import annotations

from socfw.elaborate.bus_plan import PlannedBusBridge


class SimpleBusToWishboneBridgePlanner:
    src_protocol = "simple_bus"
    dst_protocol = "wishbone"
    bridge_module = "simple_bus_to_wishbone_bridge"

    def can_bridge(self, *, fabric, ip, iface) -> bool:
        return fabric.protocol == "simple_bus" and iface.protocol == "wishbone"

    def plan_bridge(self, *, fabric, mod, ip, iface):
        return PlannedBusBridge(
            instance=f"bridge_{mod.instance}",
            module=self.bridge_module,
            src_protocol=self.src_protocol,
            dst_protocol=self.dst_protocol,
            src_fabric=fabric.name,
            dst_instance=mod.instance,
            dst_port=iface.port_name,
        )
