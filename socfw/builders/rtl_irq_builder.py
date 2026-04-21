from __future__ import annotations

from socfw.elaborate.design import ElaboratedDesign
from socfw.ir.rtl import RtlIrqCombiner, RtlIrqSource, RtlWire


class RtlIrqBuilder:
    def build(self, design: ElaboratedDesign, rtl) -> None:
        system = design.system
        irq_plan = design.irq_plan

        if system.cpu is None or system.cpu.irq_port is None:
            return
        if irq_plan is None:
            return
        if irq_plan.width <= 0:
            return

        irq_bus_name = "cpu_irq"

        rtl.add_wire_once(RtlWire(name=irq_bus_name, width=irq_plan.width, comment="CPU IRQ bus"))

        for src in irq_plan.sources:
            rtl.add_wire_once(RtlWire(name=src.signal_name, width=1, comment=f"IRQ source {src.instance}"))

        rtl.irq_combiner = RtlIrqCombiner(
            name="u_irq_combiner",
            width=irq_plan.width,
            cpu_irq_port=system.cpu.irq_port,
            cpu_irq_signal=irq_bus_name,
            sources=[
                RtlIrqSource(
                    irq_id=src.irq_id,
                    signal=src.signal_name,
                    instance=src.instance,
                )
                for src in irq_plan.sources
            ],
        )
