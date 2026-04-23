from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class ScaffoldTemplate:
    key: str
    title: str
    mode: str  # standalone / soc
    description: str
    files: tuple[str, ...] = ()
    defaults: dict = field(default_factory=dict)
