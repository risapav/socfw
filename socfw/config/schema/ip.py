from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field


class IpOriginConfig(BaseModel):
    kind: Literal["source", "vendor_generated", "generated"]
    tool: str | None = None
    packaging: str | None = None


class IpArtifactsConfig(BaseModel):
    synthesis: list[str] = Field(default_factory=list)
    simulation: list[str] = Field(default_factory=list)
    metadata: list[str] = Field(default_factory=list)
    constraints: list[str] = Field(default_factory=list)


class IpIntegrationConfig(BaseModel):
    bus: str = "none"
    generate_registers: bool = False
    instantiate: bool = True
    dependency_only: bool = False


class IpResetConfig(BaseModel):
    port: str | None = None
    bypass_sync: bool = False
    active_high: bool = False
    optional: bool = False
    asynchronous: bool = False


class IpClockOutputConfig(BaseModel):
    port: str
    domain: str | None = None
    kind: Literal["generated_clock", "status", "other"] = "generated_clock"
    signal_name: str | None = None


class IpClockingConfig(BaseModel):
    primary_input: str | None = None
    additional_inputs: list[str] = Field(default_factory=list)
    outputs: list[IpClockOutputConfig] = Field(default_factory=list)


class IpBusInterfaceConfig(BaseModel):
    port_name: str
    protocol: str
    role: Literal["slave", "master"]
    addr_width: int = 32
    data_width: int = 32


class IpV2(BaseModel):
    version: Literal[2]
    kind: Literal["ip"]
    name: str
    module: str
    category: str = "custom"
    origin: IpOriginConfig = Field(default_factory=lambda: IpOriginConfig(kind="source"))
    integration: IpIntegrationConfig = Field(default_factory=IpIntegrationConfig)
    reset: IpResetConfig = Field(default_factory=IpResetConfig)
    clocking: IpClockingConfig = Field(default_factory=IpClockingConfig)
    bus_interfaces: list[IpBusInterfaceConfig] = Field(default_factory=list)
    artifacts: IpArtifactsConfig = Field(default_factory=IpArtifactsConfig)
    params: dict[str, Any] = Field(default_factory=dict)
