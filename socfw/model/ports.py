from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class PortDescriptor:
    name: str
    direction: str
    width: int = 1
    width_expr: str | None = None  # original parametric expression, if any
