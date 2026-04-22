from __future__ import annotations

from pathlib import Path

from socfw.reports.model import BuildReport


class MarkdownReportEmitter:
    def emit(self, report: BuildReport, out_dir: str) -> str:
        out = Path(out_dir) / "reports" / "build_report.md"
        out.parent.mkdir(parents=True, exist_ok=True)

        lines: list[str] = []
        lines.append(f"# Build Report: {report.project_name}\n")
        lines.append(f"- Board: `{report.board_name}`")
        lines.append(f"- CPU: `{report.cpu_type}`")
        lines.append(f"- RAM: `{report.ram_size}` B @ `0x{report.ram_base:08X}`")
        lines.append(f"- Reset vector: `0x{report.reset_vector:08X}`")
        lines.append("")

        lines.append("## Diagnostics\n")
        if report.diagnostics:
            lines.append("| Severity | Code | Subject | Message |")
            lines.append("|----------|------|---------|---------|")
            for d in report.diagnostics:
                lines.append(f"| {d.severity} | {d.code} | {d.subject} | {d.message} |")
        else:
            lines.append("No diagnostics.")
        lines.append("")

        lines.append("## Artifacts\n")
        if report.artifacts:
            lines.append("| Family | Generator | Path |")
            lines.append("|--------|-----------|------|")
            for a in report.artifacts:
                lines.append(f"| {a.family} | {a.generator} | `{a.path}` |")
        else:
            lines.append("No artifacts.")
        lines.append("")

        lines.append("## Clock Domains\n")
        if report.clocks:
            lines.append("| Name | Freq (Hz) | Source | Reset |")
            lines.append("|------|-----------|--------|-------|")
            for c in report.clocks:
                freq = "" if c.frequency_hz is None else str(c.frequency_hz)
                lines.append(
                    f"| {c.name} | {freq} | `{c.source_kind}:{c.source_ref}` | {c.reset_policy} |"
                )
        else:
            lines.append("No clock domains.")
        lines.append("")

        lines.append("## Address Map\n")
        if report.address_regions:
            lines.append("| Name | Base | End | Size | Kind | Module |")
            lines.append("|------|------|-----|------|------|--------|")
            for r in sorted(report.address_regions, key=lambda x: x.base):
                lines.append(
                    f"| {r.name} | `0x{r.base:08X}` | `0x{r.end:08X}` | {r.size} | {r.kind} | {r.module} |"
                )
        else:
            lines.append("No address regions.")
        lines.append("")

        lines.append("## IRQ Sources\n")
        if report.irq_sources:
            lines.append("| ID | Instance | Signal |")
            lines.append("|----|----------|--------|")
            for irq in sorted(report.irq_sources, key=lambda x: x.irq_id):
                lines.append(f"| {irq.irq_id} | {irq.instance} | `{irq.signal}` |")
        else:
            lines.append("No IRQ sources.")
        lines.append("")

        lines.append("## Bus Endpoints\n")
        if report.bus_endpoints:
            lines.append("| Fabric | Instance | Module | Role | Protocol | Base | End |")
            lines.append("|--------|----------|--------|------|----------|------|-----|")
            for ep in report.bus_endpoints:
                base = "" if ep.base is None else f"`0x{ep.base:08X}`"
                end = "" if ep.end is None else f"`0x{ep.end:08X}`"
                lines.append(
                    f"| {ep.fabric} | {ep.instance} | {ep.module_type} | {ep.role} | {ep.protocol} | {base} | {end} |"
                )
        else:
            lines.append("No bus endpoints.")
        lines.append("")

        lines.append("## Planning Decisions\n")
        if report.decisions:
            for d in report.decisions:
                lines.append(f"- **{d.category}**: {d.message} — {d.rationale}")
        else:
            lines.append("No planning decisions.")
        lines.append("")

        out.write_text("\n".join(lines), encoding="utf-8")
        return str(out)
