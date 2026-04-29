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
    packs: list[str] = Field(default_factory=list)
    ip: list[str] = Field(default_factory=list)
    cpu: list[str] = Field(default_factory=list)


class FeaturesSchema(BaseModel):
    use: list[str] = Field(default_factory=list)
    profile: str | None = None


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


class BusAttachSchema(BaseModel):
    fabric: str
    base: int | None = None
    size: int | None = None


class BusFabricSchema(BaseModel):
    name: str
    protocol: str
    addr_width: int = 32
    data_width: int = 32


class ModuleSchema(BaseModel):
    instance: str
    type: str
    params: dict[str, Any] = Field(default_factory=dict)
    clocks: dict[str, str | ModuleClockPortSchema] = Field(default_factory=dict)
    bind: ModuleBindSchema = Field(default_factory=ModuleBindSchema)
    bus: BusAttachSchema | None = None
    reset: str | None = Field(
        default="auto",
        description=(
            "Per-instance reset port override. "
            "'auto' (default) connects the IP reset port to the global reset_n signal. "
            "null disables the reset connection entirely (port left unconnected). "
            "Any other string is used as a literal SystemVerilog expression "
            "(e.g. '~RESET_N' to bypass the synchronised reset and drive the port directly "
            "from the board pin — required for PLLs whose areset must not depend on locked)."
        ),
    )


class TimingRefSchema(BaseModel):
    file: str


class FirmwareSchema(BaseModel):
    enabled: bool = False
    src_dir: str | None = None
    out_dir: str = "build/fw"
    linker_script: str | None = None
    elf_file: str = "firmware.elf"
    bin_file: str = "firmware.bin"
    hex_file: str = "firmware.hex"
    tool_prefix: str = "riscv32-unknown-elf-"
    cflags: list[str] = Field(default_factory=list)
    ldflags: list[str] = Field(default_factory=list)


class ArtifactsSchema(BaseModel):
    emit: list[str] = Field(default_factory=lambda: ["rtl", "timing", "board", "docs"])


class CpuInstanceSchema(BaseModel):
    instance: str = "cpu0"
    type: str
    fabric: str
    reset_vector: int = 0
    params: dict[str, Any] = Field(default_factory=dict)


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


class ConnectionEntrySchema(BaseModel):
    # "instance.port" format
    from_: str = Field(alias="from")
    to: str

    model_config = {"populate_by_name": True}


class ProjectConfigSchema(BaseModel):
    version: Literal[2]
    kind: Literal["project"]
    project: ProjectMetaSchema
    registries: RegistriesSchema = Field(default_factory=RegistriesSchema)
    features: FeaturesSchema = Field(default_factory=FeaturesSchema)
    clocks: ClocksSchema
    cpu: CpuInstanceSchema | None = None
    ram: RamSchema | None = None
    boot: BootSchema = Field(default_factory=BootSchema)
    buses: list[BusFabricSchema] = Field(default_factory=list)
    modules: list[ModuleSchema] = Field(default_factory=list)
    connections: list[ConnectionEntrySchema] = Field(default_factory=list)
    timing: TimingRefSchema | None = None
    firmware: FirmwareSchema | None = None
    reset_driver: str | None = Field(
        default=None,
        description=(
            "Designates a module output port that drives the system reset_n signal "
            "instead of the default direct board-pin assign. "
            "Format: 'instance.port' (e.g. 'rst_sync0.rst_no'). "
            "Typical use: insert a cdc_reset_synchronizer driven by a PLL locked signal "
            "so that reset_n deasserts only after the PLL is stable. "
            "The named instance must declare the port as an output of width 1 in its IP descriptor. "
            "Note: the PLL itself must use reset: '~RESET_N' to avoid a combinational loop "
            "through its own locked output."
        ),
    )
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
