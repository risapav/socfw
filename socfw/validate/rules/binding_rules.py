from __future__ import annotations

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.model.board import BoardResource, BoardConnectorRole
from socfw.model.system import SystemModel
from .base import ValidationRule


class BindingWidthCompatibilityRule(ValidationRule):
    def validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []

        for mod in system.project.modules:
            ip = system.ip_catalog.get(mod.type_name)
            if ip is None:
                continue

            for b in mod.port_bindings:
                if not b.target.startswith("board:"):
                    continue

                try:
                    target = system.board.resolve_ref(b.target)
                except KeyError:
                    continue

                resolved_width = None
                if isinstance(target, BoardConnectorRole):
                    resolved_width = target.width
                elif isinstance(target, BoardResource):
                    sig = target.default_signal()
                    if sig is not None and hasattr(sig, "width"):
                        resolved_width = sig.width
                    elif sig is not None:
                        resolved_width = 1

                if b.width is not None and resolved_width is not None and b.width != resolved_width:
                    diags.append(
                        Diagnostic(
                            code="BND001",
                            severity=Severity.INFO,
                            message=(
                                f"Instance '{mod.instance}' port '{b.port_name}' binds to width "
                                f"{resolved_width} via explicit width {b.width}; adapter will be required"
                            ),
                            subject="project.modules.bind.ports",
                        )
                    )

        return diags
