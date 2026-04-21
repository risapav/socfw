from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field, model_validator


class CpuConfig(BaseModel):
    type: str
    params: dict[str, Any] = Field(default_factory=dict)


class RamConfig(BaseModel):
    base: int
    size: int
    latency: Literal["combinational", "registered"] = "registered"
    reset_vector: int
    stack_percent: int = 25


class MemoryConfig(BaseModel):
    ram: RamConfig


class ResetConfig(BaseModel):
    signal: str
    active_low: bool = True
    sync_stages: int = 2
    sync_from: str | None = None


class ClockConfig(BaseModel):
    name: str
    source: str
    frequency_hz: int
    reset: ResetConfig | None = None


class BusConfig(BaseModel):
    name: str
    protocol: str
    data_width: int = 32
    addr_width: int = 32
    masters: list[str] = Field(default_factory=list)
    slaves: list[str] = Field(default_factory=list)


class PeripheralBusAttach(BaseModel):
    attach: str
    base: int
    size: int


class ExternalPortBinding(BaseModel):
    top_name: str
    port: str


class PeripheralConfig(BaseModel):
    instance: str
    kind: str
    bus: PeripheralBusAttach | None = None
    clocks: list[str] = Field(default_factory=list)
    resets: list[str] = Field(default_factory=list)
    params: dict[str, Any] = Field(default_factory=dict)
    external_ports: list[ExternalPortBinding] = Field(default_factory=list)


class BoardOverridesConfig(BaseModel):
    enable_onboard: dict[str, bool] = Field(default_factory=dict)
    pmod: dict[str, str] = Field(default_factory=dict)


class TimingIoConfig(BaseModel):
    auto: bool = True
    default_input_max_ns: float = 2.5
    default_output_max_ns: float = 2.5


class TimingConfig(BaseModel):
    derive_clock_uncertainty: bool = True
    false_paths: list[dict[str, Any]] = Field(default_factory=list)
    io: TimingIoConfig = Field(default_factory=TimingIoConfig)


class ArtifactsConfig(BaseModel):
    emit: list[str] = Field(default_factory=lambda: ["rtl", "timing", "board", "software", "docs"])


class ProjectMeta(BaseModel):
    name: str
    profile: str = "default"
    board: str
    output_dir: str = "build/gen"


class PluginsConfig(BaseModel):
    model_config = {"extra": "allow"}


class ProjectV2(BaseModel):
    version: Literal[2]
    project: ProjectMeta
    cpu: CpuConfig | None = None
    memory: MemoryConfig
    clocks: list[ClockConfig]
    buses: list[BusConfig] = Field(default_factory=list)
    peripherals: list[PeripheralConfig] = Field(default_factory=list)
    board_overrides: BoardOverridesConfig = Field(default_factory=BoardOverridesConfig)
    timing: TimingConfig = Field(default_factory=TimingConfig)
    artifacts: ArtifactsConfig = Field(default_factory=ArtifactsConfig)
    plugins: PluginsConfig = Field(default_factory=PluginsConfig)

    @model_validator(mode="after")
    def _unique_names(self) -> ProjectV2:
        bus_names = [b.name for b in self.buses]
        if len(bus_names) != len(set(bus_names)):
            raise ValueError("Duplicate bus names")
        per_names = [p.instance for p in self.peripherals]
        if len(per_names) != len(set(per_names)):
            raise ValueError("Duplicate peripheral instance names")
        clk_names = [c.name for c in self.clocks]
        if len(clk_names) != len(set(clk_names)):
            raise ValueError("Duplicate clock names")
        return self
