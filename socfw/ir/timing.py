from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class TimingClock:
    name: str
    port: str
    period_ns: float
    uncertainty_ns: float | None = None


@dataclass(frozen=True)
class GeneratedClock:
    name: str
    source_pin: str
    multiply_by: int
    divide_by: int
    phase_shift_ps: int | None = None
    comment: str = ""


@dataclass(frozen=True)
class ClockGroup:
    group_type: str
    groups: tuple[tuple[str, ...], ...]


@dataclass(frozen=True)
class FalsePath:
    src: str
    dst: str
    comment: str = ""


@dataclass(frozen=True)
class IoDelay:
    port: str
    direction: str
    clock: str
    max_ns: float
    min_ns: float | None = None
    comment: str = ""


@dataclass
class TimingIR:
    clocks: list[TimingClock] = field(default_factory=list)
    generated_clocks: list[GeneratedClock] = field(default_factory=list)
    clock_groups: list[ClockGroup] = field(default_factory=list)
    false_paths: list[FalsePath] = field(default_factory=list)
    io_delays: list[IoDelay] = field(default_factory=list)
    derive_uncertainty: bool = True
