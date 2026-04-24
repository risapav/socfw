from __future__ import annotations
from dataclasses import dataclass, field
from typing import Generic, TypeVar

from .diagnostics import Diagnostic, Severity

T = TypeVar("T")


@dataclass
class Result(Generic[T]):
    value: T | None = None
    diagnostics: list[Diagnostic] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not any(d.severity == Severity.ERROR for d in self.diagnostics)

    def extend(self, diags: list) -> None:
        self.diagnostics.extend(diags)

    def require(self) -> T:
        if not self.ok or self.value is None:
            errors = [d.pretty() for d in self.diagnostics if d.severity == Severity.ERROR]
            raise RuntimeError("Result contains errors:\n" + "\n".join(errors))
        return self.value
