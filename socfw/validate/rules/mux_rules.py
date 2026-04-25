from __future__ import annotations

from socfw.core.diagnostics import Diagnostic, Severity, SourceLocation
from socfw.model.system import SystemModel
from .base import ValidationRule


class BoardMuxGroupRule(ValidationRule):
    """Enforce mutually exclusive board resource groups."""

    def validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []

        mux_groups = getattr(system.board, "mux_groups", {})
        if not mux_groups:
            return diags

        # Collect all active resource paths from features.use + bind targets
        active: set[str] = set()
        for ref in system.project.feature_refs:
            path = ref[len("board:"):] if ref.startswith("board:") else ref
            active.add(path)
        for mod in system.project.modules:
            for pb in mod.port_bindings:
                if pb.target.startswith("board:"):
                    active.add(pb.target[len("board:"):])

        if not active:
            return diags

        for group_name, group in mux_groups.items():
            if group.get("policy") != "mutually_exclusive":
                continue
            resources = group.get("resources", [])
            used = [r for r in resources if self._is_active(r, active)]
            if len(used) > 1:
                for i in range(len(used) - 1):
                    diags.append(
                        Diagnostic(
                            code="MUX001",
                            severity=Severity.ERROR,
                            message=(
                                f"Resources {used[i]} and {used[i + 1]} are mutually exclusive "
                                f"(mux_group: {group_name})"
                            ),
                            subject="project.features.use",
                            hints=(
                                f"Board mux group '{group_name}' declares these resources as mutually exclusive.",
                                "Remove one of the conflicting resources from features.use or port bindings.",
                            ),
                        )
                    )

        return diags

    def _is_active(self, resource_path: str, active: set[str]) -> bool:
        """Check if a resource path (or any active path under it) is active."""
        for a in active:
            if a == resource_path or a.startswith(resource_path + "."):
                return True
        return False
