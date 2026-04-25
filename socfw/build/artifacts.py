from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path


@dataclass(frozen=True)
class BuildArtifact:
    path: str
    kind: str
    producer: str


@dataclass
class BuildArtifactInventory:
    artifacts: list[BuildArtifact] = field(default_factory=list)

    def add(self, path: str, *, kind: str, producer: str) -> None:
        self.artifacts.append(
            BuildArtifact(
                path=str(Path(path)),
                kind=kind,
                producer=producer,
            )
        )

    def paths(self) -> list[str]:
        return sorted(dict.fromkeys(a.path for a in self.artifacts))

    def by_kind(self, kind: str) -> list[BuildArtifact]:
        return sorted(
            [a for a in self.artifacts if a.kind == kind],
            key=lambda a: a.path,
        )

    def normalized(self) -> list[BuildArtifact]:
        seen: set[tuple] = set()
        out = []
        for a in sorted(self.artifacts, key=lambda x: (x.kind, x.path, x.producer)):
            key = (a.path, a.kind, a.producer)
            if key in seen:
                continue
            seen.add(key)
            out.append(a)
        return out
