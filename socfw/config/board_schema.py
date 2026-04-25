from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field, model_validator


class BoardScalarSignalSchema(BaseModel):
    top_name: str
    direction: Literal["input", "output", "inout"]
    pin: str
    io_standard: str | None = None
    weak_pull_up: bool = False


class BoardVectorSignalSchema(BaseModel):
    top_name: str
    direction: Literal["input", "output", "inout"]
    width: int
    pins: dict[int, str] | list[str]
    io_standard: str | None = None
    weak_pull_up: bool = False

    @model_validator(mode="after")
    def _validate_shape(self) -> "BoardVectorSignalSchema":
        if isinstance(self.pins, list):
            self.pins = {i: p for i, p in enumerate(self.pins)}
        if self.width <= 0:
            raise ValueError("width must be > 0")
        if len(self.pins) != self.width:
            raise ValueError(f"width={self.width} but pins has {len(self.pins)} entries")
        missing = sorted(set(range(self.width)) - set(self.pins.keys()))
        if missing:
            raise ValueError(f"missing pin indices: {missing}")
        return self


class BoardResourceSchema(BaseModel):
    kind: str = "generic"
    top_name: str | None = None
    direction: Literal["input", "output", "inout"] | None = None
    width: int | None = None
    pins: dict[int, str] | list[str] | None = None
    pin: str | None = None
    io_standard: str | None = None
    weak_pull_up: bool = False
    model: str | None = None
    comment: str | None = None
    signals: dict[str, BoardScalarSignalSchema] = Field(default_factory=dict)
    groups: dict[str, BoardVectorSignalSchema] = Field(default_factory=dict)
    model_config = {"extra": "allow"}


class BoardConnectorRoleSchema(BaseModel):
    top_name: str
    direction: Literal["input", "output", "inout"]
    width: int
    pins: dict[int, str] | list[str]
    io_standard: str | None = None


class BoardConnectorSchema(BaseModel):
    roles: dict[str, BoardConnectorRoleSchema] = Field(default_factory=dict)


class BoardClockSchema(BaseModel):
    id: str
    top_name: str
    pin: str
    io_standard: str | None = None
    frequency_hz: int
    period_ns: float | None = None


class BoardResetSchema(BaseModel):
    id: str
    top_name: str
    pin: str
    io_standard: str | None = None
    active_low: bool = True
    weak_pull_up: bool = False


class BoardMetaSchema(BaseModel):
    id: str
    vendor: str | None = None
    title: str | None = None


class FpgaSchema(BaseModel):
    family: str
    part: str
    package: str | None = None
    pins: int | None = None
    speed: int | None = None
    hdl_default: str | None = None


class BoardResourcesSchema(BaseModel):
    onboard: dict[str, BoardResourceSchema] = Field(default_factory=dict)
    connectors: dict[str, dict[str, Any]] = Field(default_factory=dict)
    external: dict[str, Any] = Field(default_factory=dict)


class BoardSystemSchema(BaseModel):
    clock: BoardClockSchema
    reset: BoardResetSchema


class BoardProfileSchema(BaseModel):
    use: list[str] = Field(default_factory=list)
    model_config = {"extra": "allow"}


class BoardMuxGroupSchema(BaseModel):
    resources: list[str] = Field(default_factory=list)
    policy: str = "mutually_exclusive"


class BoardConfigSchema(BaseModel):
    version: Literal[2]
    kind: Literal["board"]
    board: BoardMetaSchema
    fpga: FpgaSchema
    system: BoardSystemSchema
    resources: BoardResourcesSchema = Field(default_factory=BoardResourcesSchema)
    toolchains: dict[str, Any] = Field(default_factory=dict)
    aliases: dict[str, str] = Field(default_factory=dict)
    profiles: dict[str, BoardProfileSchema] = Field(default_factory=dict)
    mux_groups: dict[str, BoardMuxGroupSchema] = Field(default_factory=dict)
    derived_resources: list[dict[str, Any]] = Field(default_factory=list)
