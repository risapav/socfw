from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass(frozen=True)
class CpuBusMaster:
    port_name: str
    protocol: str
    addr_width: int = 32
    data_width: int = 32


@dataclass
class CpuModel:
    cpu_type: str
    module: str
    params: dict[str, Any] = field(default_factory=dict)
    clock_port: str = "SYS_CLK"
    reset_port: str = "RESET_N"
    bus_master: CpuBusMaster | None = None
    irq_port: str | None = None


@dataclass
class CpuInstance:
    instance: str
    type_name: str
    fabric: str
    reset_vector: int = 0
    params: dict[str, Any] = field(default_factory=dict)
