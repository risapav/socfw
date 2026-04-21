from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class SwRegister:
    peripheral: str
    name: str
    addr: int
    access: str
    desc: str = ""


@dataclass(frozen=True)
class SwIrq:
    peripheral: str
    name: str
    irq_id: int


@dataclass
class SoftwareIR:
    board_name: str
    sys_clk_hz: int
    ram_base: int
    ram_size: int
    reset_vector: int = 0
    stack_percent: int = 25
    irq_entry_addr: int = 0x10
    registers: list[SwRegister] = field(default_factory=list)
    irqs: list[SwIrq] = field(default_factory=list)
