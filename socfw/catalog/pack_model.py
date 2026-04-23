from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class PackManifest:
    name: str
    title: str | None = None
    description: str | None = None
    provides: tuple[str, ...] = ()
