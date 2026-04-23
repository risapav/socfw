from __future__ import annotations
from dataclasses import dataclass, field


@dataclass
class CacheStageRecord:
    name: str
    fingerprint: str
    inputs: list[str] = field(default_factory=list)
    outputs: list[str] = field(default_factory=list)
    hit: bool = False
    note: str = ""


@dataclass
class CacheManifest:
    stages: dict[str, CacheStageRecord] = field(default_factory=dict)
