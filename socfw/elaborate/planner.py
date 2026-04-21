from __future__ import annotations

from socfw.builders.address_map_builder import AddressMapBuilder
from socfw.model.system import SystemModel
from socfw.plugins.simple_bus.planner import SimpleBusPlanner
from .board_bindings import BoardBindingResolver
from .bus_plan import InterconnectPlan
from .clocks import ClockResolver
from .design import ElaboratedDesign


class Elaborator:
    def __init__(self) -> None:
        self.board_bindings = BoardBindingResolver()
        self.clocks = ClockResolver()
        self.simple_bus = SimpleBusPlanner()
        self.addr_builder = AddressMapBuilder()

    def elaborate(self, system: SystemModel) -> ElaboratedDesign:
        design = ElaboratedDesign(system=system)
        design.port_bindings = self.board_bindings.resolve(system)
        design.clock_domains = self.clocks.resolve(system)

        interconnect = InterconnectPlan()
        for fabric in system.project.bus_fabrics:
            if fabric.protocol == self.simple_bus.protocol:
                plan = self.simple_bus.plan(system)
                interconnect.fabrics.update(plan.fabrics)
                interconnect.bridges.extend(plan.bridges)
        design.interconnect = interconnect

        used_types = {m.type_name for m in system.project.modules}
        for t in sorted(used_types):
            ip = system.ip_catalog.get(t)
            if ip is None:
                continue
            design.dependency_assets.extend(ip.artifacts.synthesis)

        system.peripheral_blocks = self.addr_builder.build(system, interconnect)

        return design
