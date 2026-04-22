from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class RegFieldIR:
    name: str
    offset: int
    width: int
    access: str
    reset: int
    desc: str
    word_addr: int
    hw_source: str | None = None
    write_pulse: bool = False
    clear_on_write: bool = False
    set_by_hw: bool = False
    sticky: bool = False


@dataclass
class RegisterBlockIR:
    module_name: str
    peripheral_instance: str
    base: int
    addr_width: int
    regs: list[RegFieldIR] = field(default_factory=list)
