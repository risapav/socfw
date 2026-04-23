from __future__ import annotations
from dataclasses import dataclass, field


@dataclass
class StageExecutionRecord:
    name: str
    status: str  # hit / miss / always / failed
    duration_ms: float
    fingerprint: str | None = None
    note: str = ""
    inputs: list[str] = field(default_factory=list)
    outputs: list[str] = field(default_factory=list)


@dataclass
class ArtifactProvenance:
    path: str
    family: str
    generator: str
    stage: str
    fingerprint: str | None = None
    inputs: list[str] = field(default_factory=list)


@dataclass
class BuildProvenance:
    stages: list[StageExecutionRecord] = field(default_factory=list)
    artifacts: list[ArtifactProvenance] = field(default_factory=list)
