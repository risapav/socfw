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
            except KeyError:
                diags.append(
                    Diagnostic(
                        code="BRD001",
                        severity=Severity.ERROR,
                        message=f"Unknown board feature reference '{ref}'",
                        subject="project.features.use",
                        hints=(
                            f"Reference `{ref}` was not found in board resources.",
                            "Check `resources` section in your board.yaml.",
                            "Ensure the resource key path matches the reference.",
                        ),
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
                    except KeyError:
                        diags.append(
                            Diagnostic(
                                code="BRD002",
                                severity=Severity.ERROR,
                                message=f"Instance '{mod.instance}' port '{binding.port_name}': unknown board target '{binding.target}'",
                                subject="project.modules.bind.ports",
                                hints=(
                                    f"Target `{binding.target}` was not found in board resources.",
                                    "Check `resources` section in your board.yaml.",
                                    "Use `board:<section>.<key>` format.",
                                    "Run `socfw doctor project.yaml` to inspect available resources.",
                                ),
                            )
                        )

        return diags
