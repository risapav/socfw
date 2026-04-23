from __future__ import annotations

from socfw.elaborate.design import ElaboratedDesign
from socfw.ir.software import (
    MemoryRegionIR,
    SoftwareIR,
    SwIrqIR,
    SwRegisterIR,
)


class SoftwareIRBuilder:
    def build(self, design: ElaboratedDesign) -> SoftwareIR | None:
        system = design.system

        if system.ram_size <= 0:
            return None

        cpu_desc = system.cpu_desc()
        irq_entry_addr = 0x10
        if cpu_desc is not None and cpu_desc.irq_abi is not None:
            irq_entry_addr = cpu_desc.irq_abi.irq_entry_addr

        ir = SoftwareIR(
            board_name=system.board.board_id,
            sys_clk_hz=system.board.sys_clock.frequency_hz,
            ram_base=system.ram_base,
            ram_size=system.ram_size,
            reset_vector=system.reset_vector,
            stack_percent=system.stack_percent,
            irq_entry_addr=irq_entry_addr,
        )

        ir.memory_regions.append(
            MemoryRegionIR(
                name="RAM",
                base=system.ram_base,
                size=system.ram_size,
                module="soc_ram",
                attrs={},
            )
        )

        for p in system.peripheral_blocks:
            ir.memory_regions.append(
                MemoryRegionIR(
                    name=p.instance,
                    base=p.base,
                    size=p.size,
                    module=p.module,
                    attrs={},
                )
            )

            for r in p.registers:
                ir.registers.append(
                    SwRegisterIR(
                        peripheral=p.instance,
                        peripheral_type=p.module,
                        name=r.name,
                        offset=r.offset,
                        address=p.base + r.offset,
                        access=r.access,
                        width=r.width,
                        reset=r.reset,
                        desc=r.desc,
                    )
                )

            for irq in p.irqs:
                ir.irqs.append(
                    SwIrqIR(
                        peripheral=p.instance,
                        name=irq.name,
                        irq_id=irq.irq_id,
                    )
                )

        return ir
