from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field


class TimingClockConfig(BaseModel):
    name: str
    source: str
    period_ns: float
    uncertainty_ns: float = 0.0
    reset: dict[str, Any] = Field(default_factory=dict)


class TimingGeneratedClockConfig(BaseModel):
    name: str
    source: dict[str, Any]
    multiply_by: int = 1
    divide_by: int = 1
    phase_shift_ps: int = 0
    reset: dict[str, Any] = Field(default_factory=dict)


class ClockGroupConfig(BaseModel):
    type: Literal["exclusive", "asynchronous", "physically_exclusive", "logically_exclusive"] = "exclusive"
    groups: list[list[str]] = Field(default_factory=list)


class IoDelayOverrideConfig(BaseModel):
    port: str
    direction: Literal["input", "output", "inout"]
    clock: str
    max_ns: float = 0.0
    min_ns: float = 0.0


class IoDelaysConfig(BaseModel):
    auto: bool = True
    default_input_max_ns: float = 2.5
    default_output_max_ns: float = 2.5
    overrides: list[IoDelayOverrideConfig] = Field(default_factory=list)


class FalsePathConfig(BaseModel):
    from_clock: str | None = None
    to_clock: str | None = None
    from_port: str | None = None
    to_port: str | None = None


class TimingV2(BaseModel):
    version: Literal[2]
    kind: Literal["timing"]
    timing: dict[str, Any] = Field(default_factory=dict)
    clocks: list[TimingClockConfig] = Field(default_factory=list)
    generated_clocks: list[TimingGeneratedClockConfig] = Field(default_factory=list)
    clock_groups: list[ClockGroupConfig] = Field(default_factory=list)
    false_paths: list[FalsePathConfig] = Field(default_factory=list)
    io_delays: IoDelaysConfig = Field(default_factory=IoDelaysConfig)
