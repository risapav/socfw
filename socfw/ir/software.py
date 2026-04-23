from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class SwRegisterIR:
    peripheral: str
    peripheral_type: str
    name: str
    offset: int
    address: int
    access: str
    width: int
    reset: int = 0
    desc: str = ""


@dataclass(frozen=True)
class SwIrqIR:
    peripheral: str
    name: str
    irq_id: int


@dataclass(frozen=True)
class MemoryRegionIR:
    name: str
    base: int
    size: int
    module: str
    attrs: dict[str, object] = field(default_factory=dict)

    @property
    def end(self) -> int:
        return self.base + self.size - 1


@dataclass
class SoftwareIR:
    board_name: str
    sys_clk_hz: int
    ram_base: int
    ram_size: int
    reset_vector: int
    stack_percent: int
    irq_entry_addr: int = 0x10
    memory_regions: list[MemoryRegionIR] = field(default_factory=list)
    registers: list[SwRegisterIR] = field(default_factory=list)
    irqs: list[SwIrqIR] = field(default_factory=list)
