from __future__ import annotations
from dataclasses import dataclass, field
from typing import Any


@dataclass
class EmitterRegistry:
    _emitters: dict[str, Any] = field(default_factory=dict)

    def register(self, family: str, emitter: Any) -> None:
        self._emitters[family] = emitter

    def get(self, family: str) -> Any | None:
        return self._emitters.get(family)

    def families(self) -> list[str]:
        return list(self._emitters.keys())
