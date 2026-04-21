from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field


class IpMetaSchema(BaseModel):
    name: str
    module: str
    category: str = "custom"


class IpOriginSchema(BaseModel):
    kind: Literal["source", "vendor_generated", "generated"]
    tool: str | None = None
    packaging: str | None = None


class IpIntegrationSchema(BaseModel):
    needs_bus: bool = False
    generate_registers: bool = False
    instantiate_directly: bool = True
    dependency_only: bool = False
    no_hw_warning: bool = False


class IpResetSchema(BaseModel):
    port: str | None = None
    active_high: bool = False
    bypass_sync: bool = False
    optional: bool = False
    asynchronous: bool = False


class IpClockOutputSchema(BaseModel):
    port: str
    kind: Literal["generated_clock", "status"] = "generated_clock"
    default_domain: str | None = None
    domain: str | None = None
    signal_name: str | None = None


class IpClockingSchema(BaseModel):
    primary_input_port: str | None = None
    additional_input_ports: list[str] = Field(default_factory=list)
    outputs: list[IpClockOutputSchema] = Field(default_factory=list)


class IpArtifactsSchema(BaseModel):
    synthesis: list[str] = Field(default_factory=list)
    simulation: list[str] = Field(default_factory=list)
    metadata: list[str] = Field(default_factory=list)


class IpConfigSchema(BaseModel):
    version: Literal[2]
    kind: Literal["ip"]
    ip: IpMetaSchema
    origin: IpOriginSchema = Field(default_factory=lambda: IpOriginSchema(kind="source"))
    integration: IpIntegrationSchema = Field(default_factory=IpIntegrationSchema)
    reset: IpResetSchema = Field(default_factory=IpResetSchema)
    clocking: IpClockingSchema = Field(default_factory=IpClockingSchema)
    artifacts: IpArtifactsSchema = Field(default_factory=IpArtifactsSchema)
    notes: list[str] = Field(default_factory=list)
