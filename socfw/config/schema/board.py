from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field


class FpgaConfig(BaseModel):
    family: str
    part: str
    package: str = ""
    pins: int = 0
    speed: int = 0
    hdl_default: str = "SystemVerilog_2005"


class ClockPinConfig(BaseModel):
    name: str
    top_name: str
    pin: str
    io_standard: str = "3.3-V LVTTL"
    frequency_hz: int
    period_ns: float = 0.0


class ResetPinConfig(BaseModel):
    name: str
    top_name: str
    pin: str
    io_standard: str = "3.3-V LVTTL"
    active_low: bool = True


class SystemConfig(BaseModel):
    clock: ClockPinConfig
    reset: ResetPinConfig


class VectorResourceConfig(BaseModel):
    top_name: str
    direction: Literal["input", "output", "inout"]
    width: int
    io_standard: str = "3.3-V LVTTL"
    pins: dict[int, str] = Field(default_factory=dict)


class ScalarSignalConfig(BaseModel):
    top_name: str
    direction: Literal["input", "output", "inout"]
    pin: str
    io_standard: str = "3.3-V LVTTL"


class BundleResourceConfig(BaseModel):
    io_standard: str = "3.3-V LVTTL"
    signals: dict[str, ScalarSignalConfig] = Field(default_factory=dict)
    signal_groups: dict[str, VectorResourceConfig] = Field(default_factory=dict)
    model_config = {"extra": "allow"}


class ConnectorConfig(BaseModel):
    pins: dict[int, str] = Field(default_factory=dict)


class ConnectorBankConfig(BaseModel):
    model_config = {"extra": "allow"}

    def get_connectors(self) -> dict[str, ConnectorConfig]:
        result: dict[str, ConnectorConfig] = {}
        for k, v in self.model_extra.items():
            if isinstance(v, dict) and "pins" in v:
                result[k] = ConnectorConfig(pins=v["pins"])
        return result


class ResourcesConfig(BaseModel):
    onboard: dict[str, Any] = Field(default_factory=dict)
    connectors: dict[str, Any] = Field(default_factory=dict)
    memory_devices: dict[str, Any] = Field(default_factory=dict)


class BoardMeta(BaseModel):
    id: str
    vendor: str = ""
    title: str = ""


class BoardV2(BaseModel):
    version: Literal[2]
    kind: Literal["board"]
    board: BoardMeta
    fpga: FpgaConfig
    system: SystemConfig
    resources: ResourcesConfig = Field(default_factory=ResourcesConfig)
    constraints: dict[str, Any] = Field(default_factory=dict)
    toolchains: dict[str, Any] = Field(default_factory=dict)
