from __future__ import annotations

from dataclasses import dataclass, field

from .addressing import PeripheralAddressBlock
from .board import BoardModel
from .cpu import CpuInstance
from .cpu_desc import CpuDescriptor
from .firmware import FirmwareModel
from .ip import IpDescriptor
from .memory import RamModel
from .project import ProjectModel
from .source_context import SourceContext
from .timing import TimingModel


@dataclass
class SystemModel:
    board: BoardModel
    project: ProjectModel
    timing: TimingModel | None
    ip_catalog: dict[str, IpDescriptor]
    cpu_catalog: dict[str, CpuDescriptor] = field(default_factory=dict)

    cpu: CpuInstance | None = None
    ram: RamModel | None = None
    firmware: FirmwareModel | None = None
    sources: SourceContext = field(default_factory=SourceContext)

    reset_vector: int = 0x00000000
    stack_percent: int = 25
    peripheral_blocks: list[PeripheralAddressBlock] = field(default_factory=list)

    def cpu_desc(self) -> CpuDescriptor | None:
        if self.cpu is None:
            return None
        return self.cpu_catalog.get(self.cpu.type_name)

    @property
    def ram_base(self) -> int:
        return 0 if self.ram is None else self.ram.base

    @property
    def ram_size(self) -> int:
        return 0 if self.ram is None else self.ram.size

    @property
    def cpu_type(self) -> str:
        return "none" if self.cpu is None else self.cpu.type_name

    def validate(self) -> list[str]:
        errs: list[str] = []
        errs.extend(self.board.validate())
        errs.extend(self.project.validate())
        if self.timing:
            errs.extend(self.timing.validate())
        for ip in self.ip_catalog.values():
            errs.extend(ip.validate())

        if self.ram is not None and self.reset_vector < self.ram.base:
            errs.append(
                f"reset_vector 0x{self.reset_vector:08X} is below RAM base 0x{self.ram.base:08X}"
            )

        if self.ram is not None and self.reset_vector > self.ram.base + self.ram.size - 1:
            errs.append(
                f"reset_vector 0x{self.reset_vector:08X} is outside RAM range"
            )

        seen_regions: list[tuple[str, int, int]] = []
        if self.ram is not None:
            seen_regions.append(("RAM", self.ram.base, self.ram.base + self.ram.size - 1))

        for p in self.peripheral_blocks:
            for other_name, other_base, other_end in seen_regions:
                if not (p.end < other_base or other_end < p.base):
                    errs.append(
                        f"Address overlap between '{p.instance}' "
                        f"(0x{p.base:08X}-0x{p.end:08X}) and '{other_name}' "
                        f"(0x{other_base:08X}-0x{other_end:08X})"
                    )
            seen_regions.append((p.instance, p.base, p.end))

        return errs
