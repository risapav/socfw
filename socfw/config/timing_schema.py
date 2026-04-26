from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field


class TimingResetSchema(BaseModel):
    source: str
    active_low: bool = True
    sync_stages: int = 2


class TimingPrimaryClockSchema(BaseModel):
    name: str
    source: str
    period_ns: float
    uncertainty_ns: float | None = None
    reset: TimingResetSchema | None = None


class TimingGeneratedClockSourceSchema(BaseModel):
    instance: str
    output: str


class TimingGeneratedClockSchema(BaseModel):
    name: str
    source: TimingGeneratedClockSourceSchema
    multiply_by: int = 1
    divide_by: int = 1
    pin_index: int | None = None
    phase_shift_ps: int | None = None
    reset_sync_from: str | None = None
    reset_sync_stages: int | None = None
    reset: dict[str, Any] | None = None


class ClockGroupSchema(BaseModel):
    type: str = "exclusive"
    groups: list[list[str]] = Field(default_factory=list)


class IoDelayOverrideSchema(BaseModel):
    port: str
    direction: Literal["input", "output"]
    clock: str
    max_ns: float
    min_ns: float | None = None
    comment: str = ""


class IoDelaysSchema(BaseModel):
    auto: bool = True
    default_clock: str | None = None
    default_input_max_ns: float | None = None
    default_input_min_ns: float | None = None
    default_output_max_ns: float | None = None
    default_output_min_ns: float | None = None
    overrides: list[IoDelayOverrideSchema] = Field(default_factory=list)


class FalsePathSchema(BaseModel):
    from_port: str | None = None
    from_clock: str | None = None
    to_clock: str | None = None
    from_cell: str | None = None
    to_cell: str | None = None
    comment: str = ""


class TimingConfigSchema(BaseModel):
    derive_uncertainty: bool = True
    clocks: list[TimingPrimaryClockSchema] = Field(default_factory=list)
    generated_clocks: list[TimingGeneratedClockSchema] = Field(default_factory=list)
    clock_groups: list[ClockGroupSchema] = Field(default_factory=list)
    io_delays: IoDelaysSchema = Field(default_factory=IoDelaysSchema)
    false_paths: list[FalsePathSchema] = Field(default_factory=list)


class TimingDocumentSchema(BaseModel):
    version: Literal[2]
    kind: Literal["timing"]
    timing: TimingConfigSchema
