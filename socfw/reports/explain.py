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

    def explain_bus(self, design) -> str:
        if design.interconnect is None or not design.interconnect.fabrics:
            return "No bus fabrics."

        lines = ["Bus fabrics:"]
        for fabric in sorted(design.interconnect.fabrics.keys()):
            lines.append(f"- {fabric}")
            for ep in sorted(design.interconnect.fabrics[fabric], key=lambda x: (x.role, x.instance)):
                rng = ""
                if ep.base is not None and ep.end is not None:
                    rng = f" @ 0x{ep.base:08X}-0x{ep.end:08X}"
                lines.append(f"  - {ep.role}: {ep.instance} ({ep.protocol}){rng}")
        return "\n".join(lines)

    def explain_diagnostics(self, diagnostics) -> str:
        if not diagnostics:
            return "No diagnostics."

        lines = ["Diagnostics summary:"]
        for d in diagnostics:
            lines.append(f"- {d.severity.value.upper()} {d.code}: {d.message}")
            for h in d.hints:
                lines.append(f"    hint: {h}")
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
