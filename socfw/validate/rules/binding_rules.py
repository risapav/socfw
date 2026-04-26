from __future__ import annotations

from socfw.board.selector_index import build_selector_index
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


class BindConflictRule(ValidationRule):
    """Detect multiple output drivers targeting the same board resource."""

    def validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []
        output_targets: dict[str, list[str]] = {}

        for mod in system.project.modules:
            ip = system.ip_catalog.get(mod.type_name)
            if ip is None:
                continue
            for b in mod.port_bindings:
                if not b.target.startswith("board:"):
                    continue
                ip_port = ip.port_by_name(b.port_name)
                if ip_port is None or ip_port.direction != "output":
                    continue
                key = b.target
                output_targets.setdefault(key, []).append(f"{mod.instance}.{b.port_name}")

        for target, drivers in output_targets.items():
            if len(drivers) > 1:
                diags.append(Diagnostic(
                    code="BIND020",
                    severity=Severity.ERROR,
                    message=(
                        f"Multiple output drivers for {target}: "
                        + ", ".join(drivers)
                    ),
                    subject="project.bind",
                    hints=(
                        "Only one output port may drive a board resource.",
                        "Use different targets for each instance.",
                    ),
                ))

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
                    index = build_selector_index(system.board)
                    suggestions = _suggest_for_connector(path_after_board, index)
                    hints: list[str] = [
                        f"'{b.target}' is a physical connector path, not a bindable resource.",
                    ]
                    if suggestions:
                        hints.append("Did you mean:")
                        hints.extend(f"  {s}" for s in suggestions)
                    else:
                        hints.append("Use a derived resource from the board YAML external section.")
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
                    index = build_selector_index(system.board)
                    suggestions = _suggest_closest(b.target, index)
                    hints = [f"Unknown board target '{b.target}'."]
                    if suggestions:
                        hints.append("Did you mean:")
                        hints.extend(f"  {s}" for s in suggestions)
                    else:
                        hints.append(
                            "Check available targets with: socfw board-info --selectors"
                        )
                    diags.append(Diagnostic(
                        code="BIND001",
                        severity=Severity.ERROR,
                        message=f"Unknown board binding target '{b.target}'",
                        subject="project.bind",
                        hints=tuple(hints),
                    ))
                    continue

                ip_port = ip.port_by_name(b.port_name)
                if ip_port is None:
                    continue

                res_width = _resource_width(target)

                eff_width = b.width if b.width is not None else res_width

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
                            code="BIND008",
                            severity=Severity.ERROR,
                            message=(
                                f"Adapt mode '{b.adapt}' not allowed for inout port "
                                f"{mod.instance}.{b.port_name}"
                            ),
                            subject="project.bind",
                        ))
                    elif eff_width is not None and eff_width != ip_port.width:
                        bad = _validate_adapt_widths(b.adapt, ip_port.width, eff_width)
                        if bad:
                            diags.append(Diagnostic(
                                code="BIND007",
                                severity=Severity.ERROR,
                                message=(
                                    f"Adapt '{b.adapt}' is not valid for bind {mod.instance}.{b.port_name}: "
                                    f"{bad} (IP width={ip_port.width}, target width={eff_width})"
                                ),
                                subject="project.bind",
                            ))
                elif eff_width is not None and ip_port.width != eff_width:
                    diags.append(Diagnostic(
                        code="BIND003",
                        severity=Severity.ERROR,
                        message=(
                            f"Width mismatch for bind {mod.instance}.{b.port_name}: "
                            f"IP port width {ip_port.width}, target width {eff_width}; "
                            f"use `adapt: zero_extend`, `adapt: truncate`, or `adapt: replicate`"
                        ),
                        subject="project.bind",
                    ))

        return diags


def _validate_adapt_widths(adapt: str, ip_w: int, target_w: int) -> str | None:
    """Return error reason string if this adapt/width combo is invalid, else None."""
    if adapt == "zero_extend":
        if ip_w >= target_w:
            return f"zero_extend requires IP width < target width ({ip_w} >= {target_w})"
    elif adapt == "truncate":
        if ip_w <= target_w:
            return f"truncate requires IP width > target width ({ip_w} <= {target_w})"
    elif adapt == "replicate":
        if ip_w != 1 and (target_w % ip_w != 0):
            return f"replicate requires target width divisible by IP width ({target_w} % {ip_w} != 0)"
    return None


def _suggest_for_connector(connector_path: str, index) -> list[str]:
    """Suggest bindable resources that correspond to a connector path."""
    parts = connector_path.split(".")
    if len(parts) < 3:
        return []
    conn_key = parts[2].lower()
    return [
        r for r in index.resources
        if conn_key in r.lower() and r.startswith("board:external.")
    ][:3]


def _suggest_closest(target: str, index) -> list[str]:
    """Suggest closest board resources/aliases to a typo'd target."""
    needle = target.replace("board:", "").lower()
    all_valid = index.resources + index.aliases
    scored = []
    for ref in all_valid:
        ref_path = ref.replace("board:", "").lower()
        common = sum(a == b for a, b in zip(needle, ref_path))
        if common >= min(3, len(needle) - 1):
            scored.append((common, ref))
    scored.sort(key=lambda x: -x[0])
    return [ref for _, ref in scored[:3]]


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
