from __future__ import annotations

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.model.board_resources import collect_pins, iter_resource_leaves
from socfw.model.system import SystemModel
from .base import ValidationRule


def _extract_pins(resource) -> set[str]:
    return collect_pins(resource)


def _collect_bind_targets(system: SystemModel) -> list[str]:
    """Collect all board: targets referenced in port bindings."""
    targets = []
    for mod in system.project.modules:
        for pb in mod.port_bindings:
            if pb.target.startswith("board:"):
                targets.append(pb.target)
    return targets


class BoardPinConflictRule(ValidationRule):
    def validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []

        feature_refs = system.project.feature_refs or []
        bind_targets = _collect_bind_targets(system)

        # Combine active refs: features.use + bind targets
        active_refs = list(dict.fromkeys(feature_refs + bind_targets))
        if not active_refs:
            return diags

        # build map: pin -> list of refs that use it
        pin_to_refs: dict[str, list[str]] = {}

        for ref in active_refs:
            path = ref[len("board:"):] if ref.startswith("board:") else ref
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
            unique_refs = list(dict.fromkeys(refs))
            if len(unique_refs) > 1:
                diags.append(
                    Diagnostic(
                        code="PIN001",
                        severity=Severity.ERROR,
                        message=(
                            f"Pin {pin} is used by multiple board resources: "
                            + " and ".join(unique_refs)
                        ),
                        subject="project.features.use",
                        hints=(
                            f"Physical pin `{pin}` is claimed by both {unique_refs[0]} and {unique_refs[1]}.",
                            "Remove one of the conflicting features from `features.use`, or remove the conflicting port binding.",
                        ),
                    )
                )

        return diags
