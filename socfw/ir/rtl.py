from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class RtlWire:
    name: str
    width: int = 1
    comment: str = ""


@dataclass(frozen=True)
class RtlAssign:
    lhs: str
    rhs: str
    kind: str = "comb"
    comment: str = ""


@dataclass(frozen=True)
class RtlPort:
    name: str
    direction: str
    width: int = 1


@dataclass(frozen=True)
class RtlConn:
    port: str
    signal: str


@dataclass(frozen=True)
class RtlBusConn:
    port: str
    bus_name: str


@dataclass
class RtlInstance:
    module: str
    name: str
    params: dict[str, str] = field(default_factory=dict)
    conns: list[RtlConn] = field(default_factory=list)
    bus_conns: list[RtlBusConn] = field(default_factory=list)
    comment: str = ""


@dataclass
class RtlModule:
    name: str
    ports: list[RtlPort] = field(default_factory=list)
    wires: list[RtlWire] = field(default_factory=list)
    assigns: list[RtlAssign] = field(default_factory=list)
    instances: list[RtlInstance] = field(default_factory=list)

    def add_wire_once(self, wire: RtlWire) -> None:
        if not any(w.name == wire.name for w in self.wires):
            self.wires.append(wire)


@dataclass
class RtlIR:
    top: RtlModule
    support_modules: list[RtlModule] = field(default_factory=list)
    extra_sources: list[str] = field(default_factory=list)
