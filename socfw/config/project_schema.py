from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field, model_validator


class ProjectMetaSchema(BaseModel):
    name: str
    mode: Literal["standalone", "soc"] = "standalone"
    board: str
    board_file: str | None = None
    output_dir: str = "build/gen"
    debug: bool = False


class RegistriesSchema(BaseModel):
    ip: list[str] = Field(default_factory=list)


class FeaturesSchema(BaseModel):
    use: list[str] = Field(default_factory=list)


class PrimaryClockSchema(BaseModel):
    domain: str
    source: str


class GeneratedClockSourceSchema(BaseModel):
    instance: str
    output: str


class GeneratedClockResetSchema(BaseModel):
    sync_from: str | None = None
    sync_stages: int | None = None
    none: bool = False


class GeneratedClockSchema(BaseModel):
    domain: str
    source: GeneratedClockSourceSchema
    frequency_hz: int | None = None
    reset: GeneratedClockResetSchema | None = None


class ClocksSchema(BaseModel):
    primary: PrimaryClockSchema
    generated: list[GeneratedClockSchema] = Field(default_factory=list)


class PortBindingSchema(BaseModel):
    target: str
    top_name: str | None = None
    width: int | None = None
    adapt: str | None = None


class ModuleBindSchema(BaseModel):
    ports: dict[str, PortBindingSchema] = Field(default_factory=dict)


class ModuleClockPortSchema(BaseModel):
    domain: str
    no_reset: bool = False


class ModuleSchema(BaseModel):
    instance: str
    type: str
    params: dict[str, Any] = Field(default_factory=dict)
    clocks: dict[str, str | ModuleClockPortSchema] = Field(default_factory=dict)
    bind: ModuleBindSchema = Field(default_factory=ModuleBindSchema)


class TimingRefSchema(BaseModel):
    file: str


class ArtifactsSchema(BaseModel):
    emit: list[str] = Field(default_factory=lambda: ["rtl", "timing", "board", "docs"])


class CpuSchema(BaseModel):
    type: str
    module: str
    params: dict[str, Any] = Field(default_factory=dict)
    clock_port: str = "SYS_CLK"
    reset_port: str = "RESET_N"
    irq_port: str | None = None
    bus_master_port: str | None = None
    bus_protocol: str = "simple_bus"
    addr_width: int = 32
    data_width: int = 32


class RamSchema(BaseModel):
    module: str = "soc_ram"
    base: int
    size: int
    data_width: int = 32
    addr_width: int = 32
    latency: Literal["combinational", "registered"] = "registered"
    init_file: str | None = None
    image_format: Literal["hex", "mif", "bin"] = "hex"


class BootSchema(BaseModel):
    reset_vector: int = 0
    stack_percent: int = 25


class ProjectConfigSchema(BaseModel):
    version: Literal[2]
    kind: Literal["project"]
    project: ProjectMetaSchema
    registries: RegistriesSchema = Field(default_factory=RegistriesSchema)
    features: FeaturesSchema = Field(default_factory=FeaturesSchema)
    clocks: ClocksSchema
    cpu: CpuSchema | None = None
    ram: RamSchema | None = None
    boot: BootSchema = Field(default_factory=BootSchema)
    modules: list[ModuleSchema] = Field(default_factory=list)
    timing: TimingRefSchema | None = None
    artifacts: ArtifactsSchema = Field(default_factory=ArtifactsSchema)

    @model_validator(mode="after")
    def _validate_unique_names(self) -> "ProjectConfigSchema":
        names = [m.instance for m in self.modules]
        if len(names) != len(set(names)):
            raise ValueError("duplicate module instance names")
        domains = [g.domain for g in self.clocks.generated]
        if len(domains) != len(set(domains)):
            raise ValueError("duplicate generated clock domains")
        return self
