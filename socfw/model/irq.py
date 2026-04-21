from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class IrqSource:
    instance: str
    signal_name: str
    irq_id: int


@dataclass
class IrqPlan:
    width: int
    sources: list[IrqSource] = field(default_factory=list)

    def max_irq_id(self) -> int:
        if not self.sources:
            return -1
        return max(s.irq_id for s in self.sources)
