from __future__ import annotations

from socfw.elaborate.bus_plan import ResolvedBusEndpoint
from socfw.model.system import SystemModel


class RamSlaveEndpointBuilder:
    def build(self, system: SystemModel, fabric_name: str) -> ResolvedBusEndpoint | None:
        if system.ram is None:
            return None

        return ResolvedBusEndpoint(
            instance="ram",
            module_type=system.ram.module,
            fabric=fabric_name,
            protocol="simple_bus",
            role="slave",
            port_name="bus",
            addr_width=system.ram.addr_width,
            data_width=system.ram.data_width,
            base=system.ram.base,
            size=system.ram.size,
            end=system.ram.base + system.ram.size - 1,
        )
