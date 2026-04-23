from __future__ import annotations
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class CatalogSearchPath:
    roots: list[str] = field(default_factory=list)

    def normalized(self) -> list[str]:
        return [str(Path(r).expanduser().resolve()) for r in self.roots]
