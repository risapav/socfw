from __future__ import annotations
from dataclasses import dataclass, field


@dataclass
class CatalogIndex:
    pack_roots: list[str] = field(default_factory=list)
    board_dirs: list[str] = field(default_factory=list)
    ip_dirs: list[str] = field(default_factory=list)
    cpu_dirs: list[str] = field(default_factory=list)
    vendor_dirs: list[str] = field(default_factory=list)
    example_dirs: list[str] = field(default_factory=list)
