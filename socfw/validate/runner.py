from __future__ import annotations

from socfw.core.diagnostics import Diagnostic
from socfw.model.system import SystemModel
from socfw.validate.rules.base import ValidationRule


class ValidationRunner:
    def __init__(self, rules: list[ValidationRule] | None = None):
        self.rules: list[ValidationRule] = rules or []

    def add(self, rule: ValidationRule) -> None:
        self.rules.append(rule)

    def run(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []
        for rule in self.rules:
            diags.extend(rule.validate(system))
        return diags
