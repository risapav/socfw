from __future__ import annotations

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.model.system import SystemModel
from .base import ValidationRule


class UnknownBoardFeatureRule(ValidationRule):
    def validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []

        for ref in system.project.feature_refs:
            try:
                system.board.resolve_ref(ref)
            except KeyError as e:
                diags.append(
                    Diagnostic(
                        code="BRD001",
                        severity=Severity.ERROR,
                        message=str(e),
                        subject="project.features.use",
                    )
                )

        return diags


class UnknownBoardBindingTargetRule(ValidationRule):
    def validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []

        for mod in system.project.modules:
            for binding in mod.port_bindings:
                if binding.target.startswith("board:"):
                    try:
                        system.board.resolve_ref(binding.target)
                    except KeyError as e:
                        diags.append(
                            Diagnostic(
                                code="BRD002",
                                severity=Severity.ERROR,
                                message=f"Instance '{mod.instance}' port '{binding.port_name}': {e}",
                                subject="project.modules.bind.ports",
                            )
                        )

        return diags
