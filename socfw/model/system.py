from __future__ import annotations
from dataclasses import dataclass, field

from .addressing import PeripheralAddressBlock
from .board import BoardModel
from .ip import IpDescriptor
from .project import ProjectModel
from .timing import TimingModel


@dataclass
class SystemModel:
    board: BoardModel
    project: ProjectModel
    timing: TimingModel | None
    ip_catalog: dict[str, IpDescriptor]

    # SoC/software-facing fields
    ram_base: int = 0x00000000
    ram_size: int = 0
    reset_vector: int = 0x00000000
    stack_percent: int = 25
    cpu_type: str = "none"
    peripheral_blocks: list[PeripheralAddressBlock] = field(default_factory=list)

    def validate(self) -> list[str]:
        errs: list[str] = []
        errs.extend(self.board.validate())
        errs.extend(self.project.validate())
        if self.timing:
            errs.extend(self.timing.validate())
        for ip in self.ip_catalog.values():
            errs.extend(ip.validate())

        seen_regions: list[tuple[str, int, int]] = []
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
