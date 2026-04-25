from __future__ import annotations

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.model.board_resources import collect_pins, iter_resource_leaves
from socfw.model.system import SystemModel
from .base import ValidationRule


def _extract_pins(resource) -> set[str]:
    return collect_pins(resource)


class BoardPinConflictRule(ValidationRule):
    def validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []

        if not system.project.feature_refs:
            return diags

        # build map: pin -> list of refs that use it
        pin_to_refs: dict[str, list[str]] = {}

        for ref in system.project.feature_refs:
            path = ref[len("board:"):] if ref.startswith("board:") else ref
            # Try to expand into leaf resources; falls back to single resolve
            leaves = list(iter_resource_leaves(system.board, path))
            if leaves:
                for leaf_path, leaf_res in leaves:
                    for pin in collect_pins(leaf_res):
                        pin_to_refs.setdefault(pin, []).append(ref)
            else:
                try:
                    target = system.board.resolve_ref(ref)
                except (KeyError, Exception):
                    continue
                for pin in _extract_pins(target):
                    pin_to_refs.setdefault(pin, []).append(ref)

        for pin, refs in sorted(pin_to_refs.items()):
            if len(refs) > 1:
                diags.append(
                    Diagnostic(
                        code="PIN001",
                        severity=Severity.ERROR,
                        message=(
                            f"Pin {pin} is used by multiple board features: "
                            + " and ".join(refs)
                        ),
                        subject="project.features.use",
                        hints=(
                            f"Physical pin `{pin}` is claimed by both {refs[0]} and {refs[1]}.",
                            "Remove one of the conflicting features from `features.use`.",
                            "Note: J11 PMOD pins R1/R2 conflict with SDRAM DQ — do not use both.",
                        ),
                    )
                )

        return diags
