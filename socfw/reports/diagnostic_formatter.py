from __future__ import annotations

from socfw.core.diagnostics import Diagnostic


class DiagnosticFormatter:
    def format_text(self, d: Diagnostic) -> str:
        lines: list[str] = []
        lines.append(f"{d.severity.value.upper()} {d.code} {d.subject}")
        lines.append(d.message)

        for span in d.spans:
            loc = span.file
            if span.path:
                loc += f" :: {span.path}"
            lines.append(f"at: {loc}")

        if d.detail:
            lines.append(f"detail: {d.detail}")

        if d.hints:
            lines.append("hints:")
            for h in d.hints:
                lines.append(f"- {h}")

        if d.suggested_fixes:
            lines.append("suggested fixes:")
            for fix in d.suggested_fixes:
                if fix.path:
                    lines.append(f"- {fix.message} [{fix.path}]")
                else:
                    lines.append(f"- {fix.message}")

        if d.related:
            lines.append("related:")
            for r in d.related:
                lines.append(f"- {r.code} {r.subject}: {r.message}")

        return "\n".join(lines)
