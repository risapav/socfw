from __future__ import annotations
from dataclasses import dataclass, field

BOARD_CLOCK = "SYS_CLK"
BOARD_RESET = "RESET_N"


@dataclass(frozen=True)
class RtlPort:
    name: str
    direction: str
    width: int = 1

    @property
    def width_str(self) -> str:
        return f"[{self.width - 1}:0]" if self.width > 1 else ""


@dataclass(frozen=True)
class RtlWire:
    name: str
    width: int = 1
    comment: str = ""

    @property
    def width_str(self) -> str:
        return f"[{self.width - 1}:0]" if self.width > 1 else ""


@dataclass(frozen=True)
class RtlAssign:
    lhs: str
    rhs: str
    direction: str = "comb"
    comment: str = ""


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
    params: dict[str, object] = field(default_factory=dict)
    conns: list[RtlConn] = field(default_factory=list)
    bus_conns: list[RtlBusConn] = field(default_factory=list)
    comment: str = ""


@dataclass(frozen=True)
class RtlResetSync:
    name: str
    stages: int
    clk_signal: str
    rst_out: str


@dataclass
class RtlModule:
    name: str
    ports: list[RtlPort] = field(default_factory=list)
    wires: list[RtlWire] = field(default_factory=list)
    assigns: list[RtlAssign] = field(default_factory=list)
    instances: list[RtlInstance] = field(default_factory=list)
    reset_syncs: list[RtlResetSync] = field(default_factory=list)
    extra_sources: list[str] = field(default_factory=list)

    def add_wire_once(self, wire: RtlWire) -> None:
        if not any(w.name == wire.name for w in self.wires):
            self.wires.append(wire)

    def add_port_once(self, port: RtlPort) -> None:
        if not any(p.name == port.name for p in self.ports):
            self.ports.append(port)


# Alias used by builders
RtlModuleIR = RtlModule


@dataclass
class RtlIR:
    top: RtlModule
    support_modules: list[RtlModule] = field(default_factory=list)
    extra_sources: list[str] = field(default_factory=list)
