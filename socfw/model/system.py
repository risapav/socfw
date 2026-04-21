from __future__ import annotations
from dataclasses import dataclass, field

from .board import BoardModel
from .project import ProjectModel
from .timing import TimingModel
from .ip import IpDescriptor
from .addressing import PeripheralAddressBlock


@dataclass
class SystemModel:
    board: BoardModel
    project: ProjectModel
    timing: TimingModel | None
    ip_catalog: dict[str, IpDescriptor]
    peripheral_blocks: list[PeripheralAddressBlock] = field(default_factory=list)

    def validate(self) -> list[str]:
        errs: list[str] = []
        errs.extend(self.board.validate())
        errs.extend(self.project.validate())
        if self.timing:
            errs.extend(self.timing.validate())
        for ip in self.ip_catalog.values():
            errs.extend(ip.validate())
        return errs
