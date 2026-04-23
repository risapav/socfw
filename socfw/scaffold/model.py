from __future__ import annotations
from dataclasses import dataclass


@dataclass(frozen=True)
class InitRequest:
    name: str
    out_dir: str
    template: str
    board: str | None = None
    cpu: str | None = None
    force: bool = False
