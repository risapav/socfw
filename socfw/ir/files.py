from __future__ import annotations
from dataclasses import dataclass, field


@dataclass
class FilesIR:
    rtl_files: list[str] = field(default_factory=list)
    qip_files: list[str] = field(default_factory=list)
    sdc_files: list[str] = field(default_factory=list)
