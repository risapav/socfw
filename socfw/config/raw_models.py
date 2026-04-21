from __future__ import annotations
from dataclasses import dataclass, field
from typing import Any


@dataclass
class RawDocument:
    kind: str
    data: dict[str, Any]
    source_file: str


@dataclass
class RawConfigBundle:
    project: RawDocument | None = None
    board: RawDocument | None = None
    timing: RawDocument | None = None
    ip_registry: list[RawDocument] = field(default_factory=list)
    bus_registry: list[RawDocument] = field(default_factory=list)
    extra: list[RawDocument] = field(default_factory=list)
