from __future__ import annotations

from dataclasses import dataclass
from typing import Literal


@dataclass(frozen=True)
class FirmwareArtifacts:
    elf: str
    bin: str
    hex: str


@dataclass(frozen=True)
class BootImage:
    input_file: str
    output_file: str
    input_format: Literal["bin", "elf", "hex"] = "bin"
    output_format: Literal["hex", "mif"] = "hex"
    size_bytes: int = 0
    endian: Literal["little", "big"] = "little"
