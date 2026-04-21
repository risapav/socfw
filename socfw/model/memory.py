from __future__ import annotations
from dataclasses import dataclass
from typing import Literal


@dataclass(frozen=True)
class RamModel:
    module: str
    base: int
    size: int
    data_width: int = 32
    addr_width: int = 32
    latency: Literal["combinational", "registered"] = "registered"
    init_file: str | None = None
    image_format: Literal["hex", "mif", "bin"] = "hex"
