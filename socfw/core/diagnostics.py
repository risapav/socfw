from __future__ import annotations
from dataclasses import dataclass, field
from enum import Enum


class Severity(str, Enum):
    INFO = "info"
    WARNING = "warning"
    ERROR = "error"


@dataclass(frozen=True)
class SourceLocation:
    file: str
    line: int | None = None
    column: int | None = None
    path: str | None = None


@dataclass(frozen=True)
class Diagnostic:
    code: str
    severity: Severity
    message: str
    subject: str
    locations: tuple[SourceLocation, ...] = ()
    hints: tuple[str, ...] = ()
    related: tuple[str, ...] = ()

    def pretty(self) -> str:
        parts = [f"{self.severity.value.upper()} {self.code}: {self.message}"]
        if self.locations:
            for loc in self.locations:
                line_info = f":{loc.line}" if loc.line is not None else ""
                parts.append(f"  at {loc.file}{line_info}")
        if self.hints:
            for hint in self.hints:
                parts.append(f"  hint: {hint}")
        return "\n".join(parts)
