from __future__ import annotations

from typing import Any, Literal

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
    include_dirs: list[str] = Field(default_factory=list)


class IpBusInterfaceSchema(BaseModel):
    port_name: str
    protocol: str
    role: Literal["slave", "master"]
    addr_width: int = 32
    data_width: int = 32


class IpRegisterSchema(BaseModel):
    name: str
    offset: int
    width: int = 32
    access: str = "rw"
    reset: int = 0
    desc: str = ""
    hw_source: str | None = None
    write_pulse: bool = False
    clear_on_write: bool = False
    set_by_hw: bool = False
    sticky: bool = False


class IpIrqSchema(BaseModel):
    name: str
    id: int


class IpShellPortSchema(BaseModel):
    name: str
    direction: Literal["input", "output", "inout"]
    width: int = 1


class IpShellCorePortSchema(BaseModel):
    kind: Literal["reg", "status", "irq", "external"]
    reg_name: str | None = None
    signal_name: str | None = None
    port_name: str


class IpShellSchema(BaseModel):
    module: str
    external_ports: list[IpShellPortSchema] = Field(default_factory=list)
    core_ports: list[IpShellCorePortSchema] = Field(default_factory=list)


class IpPortSchema(BaseModel):
    name: str
    direction: str
    width: int = 1
    width_expr: str | None = None


class IpParameterSchema(BaseModel):
    name: str
    type: str = "int"
    default: Any = None


class IpVendorSchema(BaseModel):
    vendor: str
    tool: str
    generator: str | None = None
    family: str | None = None
    qip: str | None = None
    sdc: list[str] = Field(default_factory=list)
    filesets: list[str] = Field(default_factory=list)


class IpConfigSchema(BaseModel):
    version: Literal[2]
    kind: Literal["ip"]
    ip: IpMetaSchema
    origin: IpOriginSchema = Field(default_factory=lambda: IpOriginSchema(kind="source"))
    vendor: IpVendorSchema | None = None
    integration: IpIntegrationSchema = Field(default_factory=IpIntegrationSchema)
    reset: IpResetSchema = Field(default_factory=IpResetSchema)
    clocking: IpClockingSchema = Field(default_factory=IpClockingSchema)
    artifacts: IpArtifactsSchema = Field(default_factory=IpArtifactsSchema)
    requires: list[str] = Field(default_factory=list)
    bus_interfaces: list[IpBusInterfaceSchema] = Field(default_factory=list)
    ports: list[IpPortSchema] = Field(default_factory=list)
    parameters: list[IpParameterSchema] = Field(default_factory=list)
    notes: list[str] = Field(default_factory=list)
    registers: list[IpRegisterSchema] = Field(default_factory=list)
    irqs: list[IpIrqSchema] = Field(default_factory=list)
    shell: IpShellSchema | None = None
