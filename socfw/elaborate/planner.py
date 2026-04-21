from __future__ import annotations

from socfw.model.system import SystemModel
from .board_bindings import BoardBindingResolver
from .bus_plan import InterconnectPlan
from .clocks import ClockResolver
from .design import ElaboratedDesign


class Elaborator:
    def __init__(self, bus_planners: dict | None = None) -> None:
        self.board_bindings = BoardBindingResolver()
        self.clocks = ClockResolver()
        self._bus_planners = bus_planners or {}

    def elaborate(self, system: SystemModel) -> ElaboratedDesign:
        design = ElaboratedDesign(system=system)
        design.port_bindings = self.board_bindings.resolve(system)
        design.clock_domains = self.clocks.resolve(system)

        interconnect = InterconnectPlan()
        for fabric in system.project.bus_fabrics:
            planner = self._bus_planners.get(fabric.protocol)
            if planner is not None:
                plan = planner.plan(system)
                interconnect.fabrics.update(plan.fabrics)
                interconnect.bridges.extend(plan.bridges)
        design.interconnect = interconnect

        used_types = {m.type_name for m in system.project.modules}
        for t in sorted(used_types):
            ip = system.ip_catalog.get(t)
            if ip is None:
                continue
            design.dependency_assets.extend(ip.artifacts.synthesis)

        return design
