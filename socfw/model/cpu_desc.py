from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass(frozen=True)
class CpuBusMasterDesc:
    port_name: str
    protocol: str
    addr_width: int = 32
    data_width: int = 32


@dataclass(frozen=True)
class CpuIrqAbi:
    kind: str
    irq_entry_addr: int = 0x10
    enable_mechanism: str = "wrapper_hook"
    return_instruction: str = "reti"


@dataclass(frozen=True)
class CpuDescriptor:
    name: str
    module: str
    family: str
    clock_port: str = "SYS_CLK"
    reset_port: str = "RESET_N"
    irq_port: str | None = None
    bus_master: CpuBusMasterDesc | None = None
    irq_abi: CpuIrqAbi | None = None
    default_params: dict[str, Any] = field(default_factory=dict)
    artifacts: tuple[str, ...] = ()
    meta: dict[str, Any] = field(default_factory=dict)
    source_file: str | None = None
