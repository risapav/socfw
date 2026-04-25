from __future__ import annotations

from copy import deepcopy

from socfw.config.normalized import NormalizedDocument
from socfw.core.diagnostics import Diagnostic, Severity, SourceLocation


def _warn(code: str, file: str, message: str, hint: str) -> Diagnostic:
    return Diagnostic(
        code=code,
        severity=Severity.WARNING,
        message=message,
        subject="board.resources",
        spans=(SourceLocation(file=file),),
        hints=(hint,),
    )


def _normalize_pins(pins, *, file: str, path: str) -> tuple[list | None, list[Diagnostic]]:
    """Normalize pins from dict {index: pin} to sorted list [pin0, pin1, ...]."""
    if pins is None:
        return None, []
    if isinstance(pins, list):
        return pins, []
    if isinstance(pins, dict):
        try:
            ordered = [v for _, v in sorted(pins.items(), key=lambda x: int(x[0]))]
            return ordered, [
                _warn(
                    "BRD_ALIAS001",
                    file,
                    f"Board resource at `{path}` uses legacy dict-style pins; prefer list",
                    "Replace `pins: {0: PIN0, 1: PIN1, ...}` with `pins: [PIN0, PIN1, ...]`.",
                )
            ]
        except (ValueError, TypeError):
            return list(pins.values()), []
    return pins, []


def _normalize_legacy_fields(node: dict, *, file: str, path: str) -> list[Diagnostic]:
    """Rename legacy field aliases in-place. Returns any warning diagnostics."""
    diags: list[Diagnostic] = []

    if "soc_top_name" in node and "top_name" not in node:
        node["top_name"] = node.pop("soc_top_name")
        diags.append(_warn("BRD_ALIAS002", file, f"soc_top_name at `{path}`; prefer `top_name`", "Replace `soc_top_name` with `top_name`."))

    if "dir" in node and "direction" not in node:
        node["direction"] = node.pop("dir")
        diags.append(_warn("BRD_ALIAS003", file, f"dir at `{path}`; prefer `direction`", "Replace `dir` with `direction`."))

    if "standard" in node and "io_standard" not in node:
        node["io_standard"] = node.pop("standard")
        diags.append(_warn("BRD_ALIAS004", file, f"standard at `{path}`; prefer `io_standard`", "Replace `standard` with `io_standard`."))

    return diags


def _normalize_resource(node: dict, *, file: str, path: str) -> tuple[dict, list[Diagnostic]]:
    d = deepcopy(node)
    diags: list[Diagnostic] = []

    diags.extend(_normalize_legacy_fields(d, file=file, path=path))

    if "pins" in d:
        normalized, pin_diags = _normalize_pins(d["pins"], file=file, path=path)
        d["pins"] = normalized
        diags.extend(pin_diags)

    # normalize nested signals in bundle
    if d.get("kind") == "bundle" and isinstance(d.get("signals"), dict):
        for sig_name, sig_val in d["signals"].items():
            if isinstance(sig_val, dict):
                normed, sig_diags = _normalize_resource(sig_val, file=file, path=f"{path}.signals.{sig_name}")
                d["signals"][sig_name] = normed
                diags.extend(sig_diags)

    return d, diags


def _walk_resources(resources: dict, *, file: str, path: str = "resources") -> tuple[dict, list[Diagnostic]]:
    if not isinstance(resources, dict):
        return resources, []

    result = {}
    diags: list[Diagnostic] = []

    for key, val in resources.items():
        cur_path = f"{path}.{key}"
        if isinstance(val, dict) and "kind" in val and (
            "top_name" in val or "soc_top_name" in val
        ):
            normed, node_diags = _normalize_resource(val, file=file, path=cur_path)
            result[key] = normed
            diags.extend(node_diags)
        elif isinstance(val, dict):
            normed, node_diags = _walk_resources(val, file=file, path=cur_path)
            result[key] = normed
            diags.extend(node_diags)
        else:
            result[key] = val

    return result, diags


def normalize_board_document(data: dict, *, file: str) -> NormalizedDocument:
    from socfw.config.normalizers.board_kind import normalize_board_resource_kinds

    d = deepcopy(data)
    diags: list[Diagnostic] = []
    aliases: list[str] = []

    resources = d.get("resources")
    if isinstance(resources, dict):
        # First infer missing kinds
        resources = normalize_board_resource_kinds(resources)
        # Then normalize legacy fields and pin formats
        normed, res_diags = _walk_resources(resources, file=file)
        d["resources"] = normed
        diags.extend(res_diags)
        for diag in res_diags:
            aliases.append(diag.message)

    return NormalizedDocument(data=d, diagnostics=diags, aliases_used=aliases)
