from __future__ import annotations

from socfw.elaborate.design import ElaboratedDesign
from socfw.ir.docs import DocsIR, DocsPeripheralIR, DocsRegisterIR


class DocsIRBuilder:
    def build(self, design: ElaboratedDesign) -> DocsIR | None:
        system = design.system

        if system.ram_size <= 0 and not system.peripheral_blocks:
            return None

        ir = DocsIR(
            board_name=system.board.board_id,
            clock_hz=system.board.sys_clock.frequency_hz,
            ram_base=system.ram_base,
            ram_size=system.ram_size,
            reset_vector=system.reset_vector,
            stack_percent=system.stack_percent,
        )

        for p in system.peripheral_blocks:
            ir.peripherals.append(
                DocsPeripheralIR(
                    instance=p.instance,
                    module=p.module,
                    base=p.base,
                    end=p.end,
                    size=p.size,
                    registers=[
                        DocsRegisterIR(
                            peripheral=p.instance,
                            name=r.name,
                            offset=r.offset,
                            access=r.access,
                            width=r.width,
                            reset=r.reset,
                            desc=r.desc,
                        )
                        for r in p.registers
                    ],
                    irq_ids=[irq.irq_id for irq in p.irqs],
                )
            )

        return ir
