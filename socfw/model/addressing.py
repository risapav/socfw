from __future__ import annotations
from dataclasses import dataclass, field

from .bus import AddressRegion


@dataclass(frozen=True)
class RegisterDef:
    name: str
    offset: int
    width: int
    access: str
    reset: int = 0
    desc: str = ""
    hw_source: str | None = None
    write_pulse: bool = False
    clear_on_write: bool = False
    set_by_hw: bool = False
    sticky: bool = False

    @property
    def address_word_offset(self) -> int:
        return self.offset // 4


@dataclass(frozen=True)
class IrqDef:
    name: str
    irq_id: int


@dataclass
class PeripheralAddressBlock:
    instance: str
    module: str
    region: AddressRegion
    registers: list[RegisterDef] = field(default_factory=list)
    irqs: list[IrqDef] = field(default_factory=list)

    @property
    def base(self) -> int:
        return self.region.base

    @property
    def end(self) -> int:
        return self.region.end

    @property
    def size(self) -> int:
        return self.region.size
