from __future__ import annotations

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.model.system import SystemModel
from .base import ValidationRule


def _extract_pins(resource) -> set[str]:
    """Extract all physical pin identifiers from a raw board resource dict or model object."""
    pins: set[str] = set()

    if isinstance(resource, dict):
        kind = resource.get("kind")
        if kind == "scalar":
            pin = resource.get("pin")
            if pin:
                pins.add(str(pin))
        elif kind in ("vector", "inout"):
            for p in (resource.get("pins") or []):
                if p:
                    pins.add(str(p))
        elif kind == "bundle":
            for sig in (resource.get("signals") or {}).values():
                if isinstance(sig, dict):
                    pins.update(_extract_pins(sig))
        else:
            # unknown kind — try pins/pin anyway
            pin = resource.get("pin")
            if pin:
                pins.add(str(pin))
            for p in (resource.get("pins") or []):
                if p:
                    pins.add(str(p))
    else:
        from socfw.model.board import BoardScalarSignal, BoardVectorSignal, BoardResource, BoardConnectorRole
        if isinstance(resource, BoardScalarSignal):
            if resource.pin:
                pins.add(resource.pin)
        elif isinstance(resource, BoardVectorSignal):
            pins.update(resource.pins.values() if isinstance(resource.pins, dict) else resource.pins)
        elif isinstance(resource, BoardResource):
            for sig in resource.scalars.values():
                pins.update(_extract_pins(sig))
            for vec in resource.vectors.values():
                pins.update(_extract_pins(vec))
        elif isinstance(resource, BoardConnectorRole):
            pins.update(resource.pins.values() if isinstance(resource.pins, dict) else resource.pins)

    return pins


class BoardPinConflictRule(ValidationRule):
    def validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []

        if not system.project.feature_refs:
            return diags

        # build map: pin -> list of refs that use it
        pin_to_refs: dict[str, list[str]] = {}

        for ref in system.project.feature_refs:
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
