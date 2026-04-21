from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class TimingPrimaryClock:
    name: str
    source_port: str
    period_ns: float
    uncertainty_ns: float | None = None
    reset_port: str | None = None
    reset_active_low: bool = True
    reset_sync_stages: int = 2


@dataclass(frozen=True)
class TimingGeneratedClock:
    name: str
    source_instance: str
    source_clock: str
    pin_index: int | None
    multiply_by: int
    divide_by: int
    phase_shift_ps: int | None = None
    sync_from: str | None = None
    sync_stages: int | None = None


@dataclass(frozen=True)
class ClockGroupConstraint:
    group_type: str
    groups: list[list[str]]


@dataclass(frozen=True)
class IoDelayOverride:
    port: str
    direction: str
    clock: str
    max_ns: float
    min_ns: float | None = None
    comment: str = ""


@dataclass(frozen=True)
class FalsePathConstraint:
    from_port: str | None = None
    from_clock: str | None = None
    to_clock: str | None = None
    from_cell: str | None = None
    to_cell: str | None = None
    comment: str = ""


@dataclass
class TimingModel:
    primary_clocks: list[TimingPrimaryClock] = field(default_factory=list)
    generated_clocks: list[TimingGeneratedClock] = field(default_factory=list)
    clock_groups: list[ClockGroupConstraint] = field(default_factory=list)
    io_auto: bool = True
    io_default_clock: str | None = None
    io_default_input_max_ns: float | None = None
    io_default_output_max_ns: float | None = None
    io_overrides: list[IoDelayOverride] = field(default_factory=list)
    false_paths: list[FalsePathConstraint] = field(default_factory=list)
    derive_uncertainty: bool = True

    def all_clock_names(self) -> set[str]:
        return (
            {c.name for c in self.primary_clocks}
            | {g.name for g in self.generated_clocks}
        )

    def validate(self) -> list[str]:
        errs: list[str] = []
        names = [c.name for c in self.primary_clocks] + [g.name for g in self.generated_clocks]

        if len(names) != len(set(names)):
            errs.append("Duplicate timing clock names")

        for g in self.generated_clocks:
            if g.multiply_by <= 0 or g.divide_by <= 0:
                errs.append(f"{g.name}: multiply_by and divide_by must be > 0")

        return errs
