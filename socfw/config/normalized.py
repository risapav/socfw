from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class NormalizedDocument:
    data: dict
    diagnostics: list = field(default_factory=list)
    aliases_used: list[str] = field(default_factory=list)
