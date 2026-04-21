from __future__ import annotations
from dataclasses import dataclass


@dataclass(frozen=True)
class Provenance:
    source_file: str
    yaml_path: str
    line: int | None = None
