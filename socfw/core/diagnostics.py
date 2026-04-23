from __future__ import annotations
from dataclasses import dataclass, field
from enum import Enum


class Severity(str, Enum):
    INFO = "info"
    WARNING = "warning"
    ERROR = "error"


@dataclass(frozen=True)
class SourceSpan:  # alias: SourceLocation
    file: str
    path: str | None = None
    line: int | None = None
    column: int | None = None
    end_line: int | None = None
    end_column: int | None = None


@dataclass(frozen=True)
class SuggestedFix:
    message: str
    replacement: str | None = None
    path: str | None = None


@dataclass(frozen=True)
class RelatedDiagnosticRef:
    code: str
    message: str
    subject: str


@dataclass(frozen=True)
class Diagnostic:
    code: str
    severity: Severity
    message: str
    subject: str
    spans: tuple[SourceSpan, ...] = ()
    hints: tuple[str, ...] = ()
    suggested_fixes: tuple[SuggestedFix, ...] = ()
    related: tuple[RelatedDiagnosticRef, ...] = ()
    category: str = "general"
    detail: str | None = None

    # backward compat alias
    @property
    def locations(self) -> tuple[SourceSpan, ...]:
        return self.spans

    def pretty(self) -> str:
        parts = [f"{self.severity.value.upper()} {self.code}: {self.message}"]
        for span in self.spans:
            loc = span.file
            if span.path:
                loc += f" :: {span.path}"
            if span.line is not None:
                loc += f":{span.line}"
            parts.append(f"  at {loc}")
        if self.hints:
            for hint in self.hints:
                parts.append(f"  hint: {hint}")
        return "\n".join(parts)


# backward-compat alias
SourceLocation = SourceSpan
