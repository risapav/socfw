from __future__ import annotations
from dataclasses import dataclass, field
from typing import Any

from .enums import BusRole


@dataclass(frozen=True)
class AddressRegion:
    base: int
    size: int

    @property
    def end(self) -> int:
        return self.base + self.size - 1


@dataclass(frozen=True)
class BusProtocolDef:
    name: str
    addr_width: int
    data_width: int
    features: tuple[str, ...] = ()


@dataclass(frozen=True)
class BusEndpoint:
    instance: str
    port_name: str
    protocol: str
    role: BusRole
    addr_width: int = 32
    data_width: int = 32
    region: AddressRegion | None = None
    clock_domain: str | None = None
    meta: dict[str, Any] = field(default_factory=dict)


@dataclass
class BusInstance:
    name: str
    protocol: str
    addr_width: int
    data_width: int
    masters: list[str] = field(default_factory=list)
    slaves: list[str] = field(default_factory=list)
    meta: dict[str, Any] = field(default_factory=dict)
