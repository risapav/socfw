from __future__ import annotations
from dataclasses import dataclass
from pathlib import Path


@dataclass
class BuildContext:
    out_dir: Path


@dataclass
class BuildRequest:
    project_file: str
    out_dir: str = "build/gen"
    artifact_families: list[str] | None = None
    profile: str = "default"

    def __post_init__(self) -> None:
        if self.artifact_families is None:
            self.artifact_families = ["rtl", "timing", "board", "software", "docs"]
