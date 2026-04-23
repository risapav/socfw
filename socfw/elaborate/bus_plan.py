from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class ResolvedBusEndpoint:
    instance: str
    module_type: str
    fabric: str
    protocol: str
    role: str
    port_name: str
    addr_width: int
    data_width: int
    base: int | None = None
    size: int | None = None
    end: int | None = None


@dataclass(frozen=True)
class PlannedBusBridge:
    instance: str
    module: str
    src_protocol: str
    dst_protocol: str
    src_fabric: str
    dst_instance: str
    dst_port: str


@dataclass
class InterconnectPlan:
    fabrics: dict[str, list[ResolvedBusEndpoint]] = field(default_factory=dict)
    bridges: list[PlannedBusBridge] = field(default_factory=list)

    def endpoints_for(self, fabric: str) -> list[ResolvedBusEndpoint]:
        return self.fabrics.get(fabric, [])
