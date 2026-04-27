from __future__ import annotations
from dataclasses import dataclass, field

BOARD_CLOCK = "SYS_CLK"
BOARD_RESET = "RESET_N"


@dataclass(frozen=True)
class RtlPort:
    name: str
    direction: str
    width: int = 1
    kind: str = "wire"

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
    interface_name: str
    modport: str


@dataclass
class RtlModuleInstance:
    module: str
    name: str
    params: dict[str, object] = field(default_factory=dict)
    conns: list[RtlConn] = field(default_factory=list)
    bus_conns: list[RtlBusConn] = field(default_factory=list)
    comment: str = ""


# Native RTL IR — lightweight frozen types for the new native emitter path

@dataclass(frozen=True)
class RtlSignal:
    name: str
    width: int = 1
    kind: str = "wire"


@dataclass(frozen=True)
class RtlConnection:
    port: str
    expr: str


@dataclass(frozen=True)
class RtlParameter:
    name: str
    value: object


@dataclass(frozen=True)
class RtlInstance:
    module: str
    instance: str
    parameters: tuple[RtlParameter, ...] = ()
    connections: tuple[RtlConnection, ...] = ()


@dataclass(frozen=True)
class RtlResetSync:
    name: str
    stages: int
    clk_signal: str
    rst_out: str


@dataclass(frozen=True)
class RtlInterfaceInstance:
    if_type: str
    name: str
    params: dict[str, object] = field(default_factory=dict)
    comment: str = ""


@dataclass(frozen=True)
class RtlFabricPort:
    port_name: str
    interface_name: str
    modport: str
    index: int | None = None


@dataclass
class RtlFabricInstance:
    module: str
    name: str
    params: dict[str, object] = field(default_factory=dict)
    clock_signal: str = BOARD_CLOCK
    reset_signal: str = BOARD_RESET
    ports: list[RtlFabricPort] = field(default_factory=list)
    comment: str = ""


@dataclass
class RtlModuleIR:
    name: str
    ports: list[RtlPort] = field(default_factory=list)
    wires: list[RtlWire] = field(default_factory=list)
    assigns: list[RtlAssign] = field(default_factory=list)
    interfaces: list[RtlInterfaceInstance] = field(default_factory=list)
    fabrics: list[RtlFabricInstance] = field(default_factory=list)
    instances: list[RtlModuleInstance] = field(default_factory=list)
    reset_syncs: list[RtlResetSync] = field(default_factory=list)
    extra_sources: list[str] = field(default_factory=list)
    irq_combiner: RtlIrqCombiner | None = field(default=None)

    def add_port_once(self, port: RtlPort) -> None:
        if all(p.name != port.name for p in self.ports):
            self.ports.append(port)

    def add_wire_once(self, wire: RtlWire) -> None:
        if all(w.name != wire.name for w in self.wires):
            self.wires.append(wire)

    def add_interface_once(self, iface: RtlInterfaceInstance) -> None:
        if all(i.name != iface.name for i in self.interfaces):
            self.interfaces.append(iface)


@dataclass(frozen=True)
class RtlIrqSource:
    irq_id: int
    signal: str
    instance: str


@dataclass
class RtlIrqCombiner:
    name: str
    width: int
    cpu_irq_port: str
    cpu_irq_signal: str
    sources: list[RtlIrqSource] = field(default_factory=list)


@dataclass
class RtlAdaptAssign:
    """Represents a width-adapt assign between a port wire and an instance signal."""
    lhs: str
    rhs: str


@dataclass
class RtlTop:
    module_name: str = "soc_top"
    ports: list[RtlPort] = field(default_factory=list)
    signals: list[RtlSignal] = field(default_factory=list)
    instances: list[RtlInstance] = field(default_factory=list)
    adapt_assigns: list[RtlAdaptAssign] = field(default_factory=list)


# Backward-compatible aliases
RtlModule = RtlModuleIR


@dataclass
class RtlIR:
    top: RtlModuleIR
    support_modules: list[RtlModuleIR] = field(default_factory=list)
    extra_sources: list[str] = field(default_factory=list)
