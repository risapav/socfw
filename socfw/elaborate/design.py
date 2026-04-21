from __future__ import annotations
from dataclasses import dataclass, field

from .board_bindings import ResolvedPortBinding
from .clocks import ResolvedClockDomain
from .bus_plan import InterconnectPlan


@dataclass
class ElaboratedDesign:
    system: object
    port_bindings: list[ResolvedPortBinding] = field(default_factory=list)
    clock_domains: list[ResolvedClockDomain] = field(default_factory=list)
    dependency_assets: list[str] = field(default_factory=list)
    interconnect: InterconnectPlan | None = None
