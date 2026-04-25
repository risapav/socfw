from __future__ import annotations

from copy import deepcopy

from socfw.core.diagnostics import Diagnostic, Severity


def alias_warning(code: str, file: str, old: str, new: str) -> Diagnostic:
    return Diagnostic(
        code=code,
        severity=Severity.WARNING,
        message=f"Deprecated config alias `{old}` used; prefer `{new}`",
        subject="config.alias",
        hints=(f"Replace `{old}` with `{new}`.",),
    )


def normalize_project_aliases(data: dict, *, file: str) -> tuple[dict, list[Diagnostic]]:
    d = deepcopy(data)
    diags: list[Diagnostic] = []

    # timing.config -> timing.file
    timing = d.get("timing")
    if isinstance(timing, dict) and "config" in timing and "file" not in timing:
        timing["file"] = timing.pop("config")
        diags.append(alias_warning("PRJ_ALIAS001", file, "timing.config", "timing.file"))

    # legacy paths.ip_plugins -> registries.ip
    paths = d.get("paths")
    if isinstance(paths, dict) and "ip_plugins" in paths:
        d.setdefault("registries", {})
        if "ip" not in d["registries"]:
            d["registries"]["ip"] = list(paths.get("ip_plugins") or [])
            diags.append(alias_warning("PRJ_ALIAS002", file, "paths.ip_plugins", "registries.ip"))

    # legacy board.type/file -> project.board/project.board_file
    board = d.get("board")
    if isinstance(board, dict):
        d.setdefault("project", {})
        if "type" in board and "board" not in d["project"]:
            d["project"]["board"] = board["type"]
            diags.append(alias_warning("PRJ_ALIAS003", file, "board.type", "project.board"))
        if "file" in board and "board_file" not in d["project"]:
            d["project"]["board_file"] = board["file"]
            diags.append(alias_warning("PRJ_ALIAS004", file, "board.file", "project.board_file"))

    # legacy design.name/mode -> project.name/mode
    design = d.get("design")
    if isinstance(design, dict):
        d.setdefault("project", {})
        if "name" in design and "name" not in d["project"]:
            d["project"]["name"] = design["name"]
            diags.append(alias_warning("PRJ_ALIAS005", file, "design.name", "project.name"))
        if "mode" in design and "mode" not in d["project"]:
            d["project"]["mode"] = design["mode"]
            diags.append(alias_warning("PRJ_ALIAS006", file, "design.mode", "project.mode"))

    # dict-style modules -> list-style modules
    modules = d.get("modules")
    if isinstance(modules, dict):
        converted = []
        for inst, spec in modules.items():
            if not isinstance(spec, dict):
                continue
            converted.append({
                "instance": inst,
                "type": spec.get("type") or spec.get("module") or inst,
                "params": spec.get("params", {}),
                "clocks": spec.get("clocks", {}),
                "bind": spec.get("bind", {}),
                "bus": spec.get("bus"),
            })
        d["modules"] = converted
        diags.append(alias_warning("PRJ_ALIAS007", file, "dict-style modules", "list-style modules"))

    return d, diags


def normalize_timing_aliases(data: dict, *, file: str) -> tuple[dict, list[Diagnostic]]:
    d = deepcopy(data)
    diags: list[Diagnostic] = []

    if "timing" not in d:
        timing: dict = {}
        moved = False

        for key in ("clocks", "generated_clocks", "io_delays", "false_paths"):
            if key in d:
                timing[key] = d.pop(key)
                moved = True

        if moved:
            d["timing"] = timing
            diags.append(alias_warning("TIM_ALIAS001", file, "top-level timing keys", "timing.*"))

    return d, diags
