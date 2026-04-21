from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class DocPeripheral:
    instance: str
    module: str
    base: int
    size: int
    registers: list[dict]
    irqs: list[dict]


@dataclass
class DocsIR:
    project_name: str
    board_name: str
    sys_clk_hz: int
    peripherals: list[DocPeripheral] = field(default_factory=list)
