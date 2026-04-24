from __future__ import annotations
from dataclasses import dataclass, field


@dataclass
class SourceContext:
    project_file: str | None = None
    board_file: str | None = None
    timing_file: str | None = None
    ip_files: dict[str, str] = field(default_factory=dict)
    cpu_files: dict[str, str] = field(default_factory=dict)
    pack_roots: list[str] = field(default_factory=list)
    ip_search_dirs: list[str] = field(default_factory=list)
    cpu_search_dirs: list[str] = field(default_factory=list)
