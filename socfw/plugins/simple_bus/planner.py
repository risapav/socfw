from __future__ import annotations

from socfw.elaborate.bus_plan import InterconnectPlan, ResolvedBusEndpoint
from socfw.model.system import SystemModel
from socfw.plugins.bridges.simple_to_axi import SimpleBusToAxiLiteBridgePlanner
from socfw.plugins.bus_api import BusPlanner
from socfw.plugins.simple_bus.cpu_endpoint import CpuMasterEndpointBuilder
from socfw.plugins.simple_bus.ram_endpoint import RamSlaveEndpointBuilder


class SimpleBusPlanner(BusPlanner):
    protocol = "simple_bus"

    def __init__(self) -> None:
        self.cpu_builder = CpuMasterEndpointBuilder()
        self.ram_builder = RamSlaveEndpointBuilder()
        self.bridge_planner = SimpleBusToAxiLiteBridgePlanner()

    def plan(self, system: SystemModel) -> InterconnectPlan:
        plan = InterconnectPlan()

        for fabric in system.project.bus_fabrics:
            if fabric.protocol != self.protocol:
                continue

            endpoints: list[ResolvedBusEndpoint] = []

            cpu_ep = self.cpu_builder.build(system, fabric.name)
            if cpu_ep is not None:
                endpoints.append(cpu_ep)

            ram_ep = self.ram_builder.build(system, fabric.name)
            if ram_ep is not None:
                endpoints.append(ram_ep)

            for mod in system.project.modules:
                if mod.bus is None or mod.bus.fabric != fabric.name:
                    continue

                ip = system.ip_catalog.get(mod.type_name)
                if ip is None:
                    continue

                iface = ip.bus_interface(role="slave") or ip.bus_interface()
                if iface is None:
                    continue

                base = mod.bus.base
                size = mod.bus.size
                end = None if (base is None or size is None) else (base + size - 1)

                if iface.protocol == "simple_bus":
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
                else:
                    bridge = self.bridge_planner.maybe_plan_bridge(
                        fabric=fabric,
                        mod=mod,
                        ip=ip,
                    )
                    if bridge is not None:
                        plan.bridges.append(bridge)
                        endpoints.append(
                            ResolvedBusEndpoint(
                                instance=bridge.instance,
                                module_type=bridge.module,
                                fabric=fabric.name,
                                protocol="simple_bus",
                                role="slave",
                                port_name="sbus",
                                addr_width=fabric.addr_width,
                                data_width=fabric.data_width,
                                base=base,
                                size=size,
                                end=end,
                            )
                        )

            plan.fabrics[fabric.name] = endpoints

        return plan
