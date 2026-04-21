from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class PinAssignment:
    top_name: str
    pin: str
    io_standard: str | None = None


@dataclass(frozen=True)
class VectorPinAssignment:
    top_name: str
    width: int
    pins: dict[int, str]
    io_standard: str | None = None


@dataclass
class BoardIR:
    fpga_family: str
    fpga_part: str
    scalar_pins: list[PinAssignment] = field(default_factory=list)
    vector_pins: list[VectorPinAssignment] = field(default_factory=list)
    dependency_files: list[str] = field(default_factory=list)
    output_files: dict[str, str] = field(default_factory=dict)
