from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class PortDescriptor:
    name: str
    direction: str
    width: int = 1
