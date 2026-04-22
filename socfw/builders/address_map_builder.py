from __future__ import annotations

from socfw.elaborate.bus_plan import InterconnectPlan
from socfw.model.addressing import AddressRegion, IrqDef, PeripheralAddressBlock, RegisterDef
from socfw.model.system import SystemModel


class AddressMapBuilder:
    def build(self, system: SystemModel, plan: InterconnectPlan) -> list[PeripheralAddressBlock]:
        blocks: list[PeripheralAddressBlock] = []

        for fabric_name, endpoints in plan.fabrics.items():
            for ep in endpoints:
                if ep.role != "slave":
                    continue
                if ep.base is None or ep.size is None:
                    continue

                ip = system.ip_catalog.get(ep.module_type)
                if ip is None:
                    continue

                reg_defs = []
                irq_defs = []

                regs_meta = ip.meta.get("registers", [])
                for r in regs_meta:
                    reg_defs.append(
                        RegisterDef(
                            name=r["name"],
                            offset=int(r["offset"]),
                            width=int(r.get("width", 32)),
                            access=str(r.get("access", "rw")),
                            reset=int(r.get("reset", 0)),
                            desc=str(r.get("desc", "")),
                            hw_source=r.get("hw_source"),
                            write_pulse=bool(r.get("write_pulse", False)),
                        )
                    )

                irqs_meta = ip.meta.get("irqs", [])
                for irq in irqs_meta:
                    irq_defs.append(
                        IrqDef(
                            name=str(irq["name"]),
                            irq_id=int(irq["id"]),
                        )
                    )

                blocks.append(
                    PeripheralAddressBlock(
                        instance=ep.instance,
                        module=ep.module_type,
                        region=AddressRegion(base=ep.base, size=ep.size),
                        registers=reg_defs,
                        irqs=irq_defs,
                    )
                )

        return blocks
