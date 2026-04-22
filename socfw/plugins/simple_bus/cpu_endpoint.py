from __future__ import annotations

from socfw.elaborate.bus_plan import ResolvedBusEndpoint
from socfw.model.system import SystemModel


class CpuMasterEndpointBuilder:
    def build(self, system: SystemModel, fabric_name: str) -> ResolvedBusEndpoint | None:
        if system.cpu is None or system.cpu.fabric != fabric_name:
            return None

        desc = system.cpu_desc()
        if desc is None or desc.bus_master is None:
            return None

        return ResolvedBusEndpoint(
            instance=system.cpu.instance,
            module_type=system.cpu.type_name,
            fabric=fabric_name,
            protocol=desc.bus_master.protocol,
            role="master",
            port_name=desc.bus_master.port_name,
            addr_width=desc.bus_master.addr_width,
            data_width=desc.bus_master.data_width,
            base=None,
            size=None,
            end=None,
        )
