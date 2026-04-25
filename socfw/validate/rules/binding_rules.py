from __future__ import annotations

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.model.board import BoardResource, BoardConnectorRole, BoardScalarSignal, BoardVectorSignal
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


class BoardBindingRule(ValidationRule):
    def validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []

        for midx, mod in enumerate(system.project.modules):
            ip = system.ip_catalog.get(mod.type_name)
            if ip is None:
                continue

            for b in mod.port_bindings:
                if not b.target.startswith("board:"):
                    continue

                try:
                    target = system.board.resolve_ref(b.target)
                except (KeyError, Exception):
                    target = None

                if target is None:
                    diags.append(Diagnostic(
                        code="BIND001",
                        severity=Severity.ERROR,
                        message=f"Unknown board binding target '{b.target}'",
                        subject="project.bind",
                    ))
                    continue

                ip_port = ip.port_by_name(b.port_name)
                if ip_port is None:
                    continue

                res_width = _resource_width(target)
                if res_width is not None and ip_port.width != res_width:
                    diags.append(Diagnostic(
                        code="BIND003",
                        severity=Severity.ERROR,
                        message=(
                            f"Width mismatch for bind {mod.instance}.{b.port_name}: "
                            f"IP port width {ip_port.width}, board resource width {res_width}"
                        ),
                        subject="project.bind",
                    ))

        return diags


def _resource_width(target) -> int | None:
    if isinstance(target, BoardVectorSignal):
        return target.width
    if isinstance(target, BoardScalarSignal):
        return 1
    if isinstance(target, BoardResource):
        sig = target.default_signal()
        if isinstance(sig, BoardVectorSignal):
            return sig.width
        if isinstance(sig, BoardScalarSignal):
            return 1
    if isinstance(target, BoardConnectorRole):
        return target.width
    if isinstance(target, dict):
        return int(target.get("width", 1))
    return None
