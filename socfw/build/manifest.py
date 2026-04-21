from __future__ import annotations
from dataclasses import dataclass, field


@dataclass
class GeneratedArtifact:
    path: str
    family: str
    generator: str
    metadata: dict = field(default_factory=dict)


@dataclass
class BuildManifest:
    artifacts: list[GeneratedArtifact] = field(default_factory=list)

    def add(self, family: str, path: str, generator: str, metadata: dict | None = None) -> None:
        self.artifacts.append(
            GeneratedArtifact(
                path=path,
                family=family,
                generator=generator,
                metadata=metadata or {},
            )
        )
