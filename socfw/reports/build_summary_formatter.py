from __future__ import annotations


class BuildSummaryFormatter:
    def format_text(self, provenance) -> str:
        lines: list[str] = []
        lines.append("Build summary:")

        for s in provenance.stages:
            dur = f"{s.duration_ms:.1f} ms"
            msg = f"- {s.name}: {s.status} ({dur})"
            if s.note:
                msg += f" - {s.note}"
            lines.append(msg)

        return "\n".join(lines)
