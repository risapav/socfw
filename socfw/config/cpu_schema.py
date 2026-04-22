from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field


class CpuBusMasterSchema(BaseModel):
    port_name: str
    protocol: str
    addr_width: int = 32
    data_width: int = 32


class CpuDescriptorMetaSchema(BaseModel):
    name: str
    module: str
    family: str


class CpuDescriptorSchema(BaseModel):
    version: Literal[2]
    kind: Literal["cpu"]
    cpu: CpuDescriptorMetaSchema
    clock_port: str = "SYS_CLK"
    reset_port: str = "RESET_N"
    irq_port: str | None = None
    bus_master: CpuBusMasterSchema | None = None
    default_params: dict[str, Any] = Field(default_factory=dict)
    artifacts: list[str] = Field(default_factory=list)
    notes: list[str] = Field(default_factory=list)
