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
class RtlAdaptAssign:
    lhs: str
    rhs: str


@dataclass
class RtlTop:
    module_name: str = "soc_top"
    ports: list[RtlPort] = field(default_factory=list)
    signals: list[RtlSignal] = field(default_factory=list)
    instances: list[RtlInstance] = field(default_factory=list)
    adapt_assigns: list[RtlAdaptAssign] = field(default_factory=list)
