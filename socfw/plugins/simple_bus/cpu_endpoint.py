from __future__ import annotations

from socfw.elaborate.bus_plan import ResolvedBusEndpoint
from socfw.model.system import SystemModel


class CpuMasterEndpointBuilder:
    def build(self, system: SystemModel, fabric_name: str) -> ResolvedBusEndpoint | None:
        if system.cpu is None or system.cpu.bus_master is None:
            return None

        return ResolvedBusEndpoint(
            instance="cpu",
            module_type=system.cpu.cpu_type,
            fabric=fabric_name,
            protocol=system.cpu.bus_master.protocol,
            role="master",
            port_name=system.cpu.bus_master.port_name,
            addr_width=system.cpu.bus_master.addr_width,
            data_width=system.cpu.bus_master.data_width,
            base=None,
            size=None,
            end=None,
        )
