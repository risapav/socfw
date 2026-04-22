from __future__ import annotations

import math

from socfw.ir.register_block import RegFieldIR, RegisterBlockIR
from socfw.model.addressing import PeripheralAddressBlock


class RegisterBlockIRBuilder:
    def build_for_peripheral(self, p: PeripheralAddressBlock) -> RegisterBlockIR | None:
        if not p.registers:
            return None

        word_count = max((r.offset // 4) for r in p.registers) + 1
        addr_width = max(1, math.ceil(math.log2(word_count)))

        return RegisterBlockIR(
            module_name=f"{p.instance}_regs",
            peripheral_instance=p.instance,
            base=p.base,
            addr_width=addr_width,
            regs=[
                RegFieldIR(
                    name=r.name,
                    offset=r.offset,
                    width=r.width,
                    access=r.access,
                    reset=r.reset,
                    desc=r.desc,
                    word_addr=r.address_word_offset,
                    hw_source=r.hw_source,
                    write_pulse=r.write_pulse,
                )
                for r in p.registers
            ],
        )
