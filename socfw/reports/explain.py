from __future__ import annotations


class ExplainService:
    def explain_clocks(self, design) -> str:
        lines = ["Clock domains:"]
        for c in design.clock_domains:
            freq = "unknown" if c.frequency_hz is None else f"{c.frequency_hz} Hz"
            lines.append(
                f"- {c.name}: {freq}, source={c.source_kind}:{c.source_ref}, reset={c.reset_policy}"
            )
        return "\n".join(lines)

    def explain_address_map(self, system) -> str:
        lines = ["Address map:"]
        if system.ram is not None:
            lines.append(
                f"- RAM: 0x{system.ram.base:08X} .. 0x{system.ram.base + system.ram.size - 1:08X}"
            )
        for p in sorted(system.peripheral_blocks, key=lambda x: x.base):
            lines.append(f"- {p.instance}: 0x{p.base:08X} .. 0x{p.end:08X} ({p.module})")
        return "\n".join(lines)

    def explain_irqs(self, design) -> str:
        if design.irq_plan is None or not design.irq_plan.sources:
            return "No IRQ sources."
        lines = [f"IRQ map (width={design.irq_plan.width}):"]
        for src in design.irq_plan.sources:
            lines.append(f"- irq[{src.irq_id}] <- {src.instance}.{src.signal_name}")
        return "\n".join(lines)

    def explain_cpu_irq(self, system) -> str:
        cpu = system.cpu
        desc = system.cpu_desc()
        if cpu is None or desc is None or desc.irq_abi is None:
            return "No CPU IRQ ABI configured."

        abi = desc.irq_abi
        return (
            f"CPU IRQ ABI:\n"
            f"- CPU type: {cpu.type_name}\n"
            f"- ABI kind: {abi.kind}\n"
            f"- IRQ entry address: 0x{abi.irq_entry_addr:08X}\n"
            f"- Enable mechanism: {abi.enable_mechanism}\n"
            f"- Return instruction: {abi.return_instruction}"
        )
