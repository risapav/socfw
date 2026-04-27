from __future__ import annotations

from socfw.board.feature_expansion import expand_features, expand_features_for_project
from socfw.board.pin_ownership import PinUse, collect_pin_ownership
from socfw.core.diagnostics import Diagnostic, Severity
from socfw.model.board_resources import collect_pins
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


def _prune_subpaths(refs: list[str]) -> list[str]:
    """Remove refs that are sub-paths of another ref in the list."""
    paths = [r[len("board:"):] if r.startswith("board:") else r for r in refs]
    pruned = []
    for i, ref in enumerate(refs):
        path = paths[i]
        dominated = False
        for j, other_path in enumerate(paths):
            if i != j and path != other_path and path.startswith(other_path + "."):
                dominated = True
                break
        if not dominated:
            pruned.append(ref)
    return pruned


def _pin_use_label(use: PinUse) -> str:
    if use.bit is not None:
        return f"{use.resource_path}[{use.bit}]"
    return use.resource_path


class BoardPinConflictRule(ValidationRule):
    def validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []

        project = system.project
        board = system.board

        # Build selected resources from features + bind targets (with inference fallback)
        selected = expand_features_for_project(board, project)

        # Also include direct bind targets that reference external paths
        bind_targets = _collect_bind_targets(system)
        for ref in bind_targets:
            if not ref.startswith("board:"):
                continue
            path = ref[len("board:"):]
            # Add bind targets as explicit use refs so they appear in ownership
            if path not in selected.paths:
                selected.paths.append(path)

        selected.paths = _prune_subpaths(
            [f"board:{p}" for p in selected.paths]
        )
        selected.paths = [p[len("board:"):] if p.startswith("board:") else p for p in selected.paths]

        if not selected.paths:
            return diags

        pin_uses = collect_pin_ownership(board, selected)

        # Build map: pin -> list of PinUse that claim it
        pin_to_uses: dict[str, list[PinUse]] = {}
        for use in pin_uses:
            pin_to_uses.setdefault(use.pin, []).append(use)

        for pin, uses in sorted(pin_to_uses.items()):
            # Deduplicate by resource_path+bit
            seen: set[tuple] = set()
            unique: list[PinUse] = []
            for u in uses:
                key = (u.resource_path, u.bit)
                if key not in seen:
                    seen.add(key)
                    unique.append(u)

            if len(unique) > 1:
                labels = " and ".join(_pin_use_label(u) for u in unique)
                diags.append(
                    Diagnostic(
                        code="PIN001",
                        severity=Severity.ERROR,
                        message=f"pin {pin} selected by both {labels}",
                        subject="project.features.use",
                        hints=(
                            f"Physical pin `{pin}` is claimed by {_pin_use_label(unique[0])} and {_pin_use_label(unique[1])}.",
                            "Remove one of the conflicting features from `features.use`, or remove the conflicting port binding.",
                        ),
                    )
                )

        return diags
