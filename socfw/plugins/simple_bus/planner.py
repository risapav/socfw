from __future__ import annotations

from socfw.elaborate.bus_plan import InterconnectPlan, ResolvedBusEndpoint
from socfw.plugins.bus_api import BusPlanner


class SimpleBusPlanner(BusPlanner):
    protocol = "simple_bus"

    def plan(self, system) -> InterconnectPlan:
        plan = InterconnectPlan()

        for fabric in system.project.bus_fabrics:
            if fabric.protocol != self.protocol:
                continue

            endpoints: list[ResolvedBusEndpoint] = []

            for mod in system.project.modules:
                if mod.bus is None or mod.bus.fabric != fabric.name:
                    continue

                ip = system.ip_catalog.get(mod.type_name)
                if ip is None:
                    continue

                iface = ip.bus_interface()
                if iface is None:
                    continue

                base = mod.bus.base
                size = mod.bus.size
                end = None if (base is None or size is None) else (base + size - 1)

                endpoints.append(
                    ResolvedBusEndpoint(
                        instance=mod.instance,
                        module_type=mod.type_name,
                        fabric=fabric.name,
                        protocol=iface.protocol,
                        role=iface.role,
                        port_name=iface.port_name,
                        addr_width=iface.addr_width,
                        data_width=iface.data_width,
                        base=base,
                        size=size,
                        end=end,
                    )
                )

            plan.fabrics[fabric.name] = endpoints

        return plan
