from __future__ import annotations

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.model.board import BoardResource, BoardConnectorRole, BoardScalarSignal, BoardVectorSignal
from socfw.model.system import SystemModel
from .base import ValidationRule

_VALID_ADAPT_MODES = frozenset({"zero_extend", "truncate", "replicate"})


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

                path_after_board = b.target[len("board:"):]
                if path_after_board.startswith("connectors."):
                    derived = _suggest_derived(path_after_board, system.board)
                    hints = [
                        "Connector paths describe physical pins, not bindable resources.",
                        "Define a derived resource in the board YAML:",
                        "  derived_resources:",
                        f"    - name: external.pmod.{path_after_board.split('.')[-1].lower()}_gpio8",
                        f"      from: {path_after_board}",
                        "      role: gpio8",
                        "      top_name: PMOD_D",
                    ]
                    if derived:
                        hints = [f"Use derived resource: board:{derived}"] + hints
                    diags.append(Diagnostic(
                        code="BRD003",
                        severity=Severity.ERROR,
                        message=f"'{b.target}' is a connector path, not a bindable resource",
                        subject="project.bind",
                        hints=tuple(hints),
                    ))
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

                if b.adapt is not None:
                    if b.adapt not in _VALID_ADAPT_MODES:
                        diags.append(Diagnostic(
                            code="BIND006",
                            severity=Severity.ERROR,
                            message=(
                                f"Invalid adapt mode '{b.adapt}' for bind {mod.instance}.{b.port_name}; "
                                f"valid modes: {', '.join(sorted(_VALID_ADAPT_MODES))}"
                            ),
                            subject="project.bind",
                        ))
                    elif ip_port.direction not in ("input", "output"):
                        diags.append(Diagnostic(
                            code="BIND007",
                            severity=Severity.ERROR,
                            message=(
                                f"Adapt mode '{b.adapt}' not allowed for inout port "
                                f"{mod.instance}.{b.port_name}"
                            ),
                            subject="project.bind",
                        ))
                elif res_width is not None and ip_port.width != res_width:
                    diags.append(Diagnostic(
                        code="BIND003",
                        severity=Severity.ERROR,
                        message=(
                            f"Width mismatch for bind {mod.instance}.{b.port_name}: "
                            f"IP port width {ip_port.width}, board resource width {res_width}; "
                            f"use `adapt: zero_extend`, `adapt: truncate`, or `adapt: replicate`"
                        ),
                        subject="project.bind",
                    ))

        return diags


def _suggest_derived(connector_path: str, board) -> str | None:
    """Suggest a derived resource path for a connector path."""
    external = board.resources.get("external") or {}
    parts = connector_path.split(".")
    if len(parts) >= 3:
        conn_section = parts[1]
        conn_key = parts[2].lower()
        section = external.get(conn_section, {})
        if isinstance(section, dict) and conn_key in section:
            sub = section[conn_key]
            if isinstance(sub, dict):
                first = next(iter(sub), None)
                if first:
                    return f"external.{conn_section}.{conn_key}.{first}"
    return None


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
