from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class DocsRegisterIR:
    peripheral: str
    name: str
    offset: int
    access: str
    width: int
    reset: int
    desc: str = ""


@dataclass(frozen=True)
class DocsPeripheralIR:
    instance: str
    module: str
    base: int
    end: int
    size: int
    registers: list[DocsRegisterIR] = field(default_factory=list)
    irq_ids: list[int] = field(default_factory=list)


@dataclass
class DocsIR:
    board_name: str
    clock_hz: int
    ram_base: int
    ram_size: int
    reset_vector: int
    stack_percent: int
    peripherals: list[DocsPeripheralIR] = field(default_factory=list)
