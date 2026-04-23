from __future__ import annotations

from socfw.elaborate.bus_plan import PlannedBusBridge


class SimpleBusToAxiLiteBridgePlanner:
    src_protocol = "simple_bus"
    dst_protocol = "axi_lite"
    bridge_module = "simple_bus_to_axi_lite_bridge"

    def can_bridge(self, *, fabric, ip, iface) -> bool:
        return fabric.protocol == self.src_protocol and iface.protocol == self.dst_protocol

    def plan_bridge(self, *, fabric, mod, ip, iface) -> PlannedBusBridge:
        return PlannedBusBridge(
            instance=f"bridge_{mod.instance}",
            module=self.bridge_module,
            src_protocol=self.src_protocol,
            dst_protocol=self.dst_protocol,
            src_fabric=fabric.name,
            dst_instance=mod.instance,
            dst_port=iface.port_name,
        )

    def maybe_plan_bridge(self, *, fabric, mod, ip) -> PlannedBusBridge | None:
        iface = ip.bus_interface(role="slave")
        if iface is None:
            return None
        if not self.can_bridge(fabric=fabric, ip=ip, iface=iface):
            return None
        return self.plan_bridge(fabric=fabric, mod=mod, ip=ip, iface=iface)
