from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class ClockConstraint:
    name: str
    source_port: str
    period_ns: float
    uncertainty_ns: float | None = None


@dataclass(frozen=True)
class GeneratedClockConstraint:
    name: str
    source_instance: str
    source_output: str
    source_clock: str
    multiply_by: int
    divide_by: int
    pin_index: int | None = None
    phase_shift_ps: int | None = None


@dataclass(frozen=True)
class FalsePathConstraintIR:
    from_port: str | None = None
    from_clock: str | None = None
    to_clock: str | None = None
    from_cell: str | None = None
    to_cell: str | None = None
    comment: str = ""


@dataclass(frozen=True)
class IoDelayConstraintIR:
    port: str
    direction: str
    clock: str
    max_ns: float
    min_ns: float | None = None
    comment: str = ""


@dataclass
class TimingIR:
    clocks: list[ClockConstraint] = field(default_factory=list)
    generated_clocks: list[GeneratedClockConstraint] = field(default_factory=list)
    clock_groups: list[dict] = field(default_factory=list)
    false_paths: list[FalsePathConstraintIR] = field(default_factory=list)
    io_delays: list[IoDelayConstraintIR] = field(default_factory=list)
    derive_uncertainty: bool = True
