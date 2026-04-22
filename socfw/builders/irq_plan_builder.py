from __future__ import annotations

from socfw.model.irq import IrqPlan, IrqSource
from socfw.model.system import SystemModel


class IrqPlanBuilder:
    def build(self, system: SystemModel) -> IrqPlan | None:
        if system.cpu is None:
            return None
        cpu_desc = system.cpu_desc()
        if cpu_desc is None or cpu_desc.irq_port is None:
            return None

        sources: list[IrqSource] = []

        for p in system.peripheral_blocks:
            for irq in p.irqs:
                sources.append(
                    IrqSource(
                        instance=p.instance,
                        signal_name=f"irq_{p.instance}_{irq.name}",
                        irq_id=irq.irq_id,
                    )
                )

        if not sources:
            return IrqPlan(width=0, sources=[])

        width = max(s.irq_id for s in sources) + 1
        return IrqPlan(width=width, sources=sorted(sources, key=lambda s: s.irq_id))
