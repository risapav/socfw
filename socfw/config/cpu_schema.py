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


class CpuIrqAbiSchema(BaseModel):
    kind: Literal["picorv32_native", "wrapper_minimal"]
    irq_entry_addr: int = 0x10
    enable_mechanism: Literal["wrapper_hook", "native_sw"] = "wrapper_hook"
    return_instruction: str = "reti"


class CpuDescriptorSchema(BaseModel):
    version: Literal[2]
    kind: Literal["cpu"]
    cpu: CpuDescriptorMetaSchema
    clock_port: str = "SYS_CLK"
    reset_port: str = "RESET_N"
    irq_port: str | None = None
    bus_master: CpuBusMasterSchema | None = None
    irq_abi: CpuIrqAbiSchema | None = None
    default_params: dict[str, Any] = Field(default_factory=dict)
    artifacts: list[str] = Field(default_factory=list)
    notes: list[str] = Field(default_factory=list)
