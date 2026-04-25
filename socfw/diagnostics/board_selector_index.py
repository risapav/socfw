from __future__ import annotations

import json
from pathlib import Path

from socfw.board.resource_tree import iter_resource_leaves
from socfw.model.board import BoardModel


def build_selector_index(board: BoardModel) -> dict:
    """Build a JSON-serializable index of all board selectors for editor support."""
    resources: list[str] = []
    aliases: list[str] = []
    profiles: list[str] = []

    # Onboard resources
    for key, res in board.onboard.items():
        resources.append(f"board:onboard.{key}")
        for sig_key in res.scalars:
            if sig_key != "default":
                resources.append(f"board:onboard.{key}.{sig_key}")
        for vec_key in res.vectors:
            if vec_key != "default":
                resources.append(f"board:onboard.{key}.{vec_key}")

    # External resources via tree traversal
    external = board.resources.get("external") or {}
    for leaf_path, _ in iter_resource_leaves(external, ""):
        path = leaf_path.lstrip(".")
        if path:
            resources.append(f"board:external.{path}")

    # Aliases
    for alias_key in board.aliases:
        aliases.append(f"board:@{alias_key}")

    # Profiles
    for profile_name in board.profiles:
        profiles.append(profile_name)

    return {
        "board_id": board.board_id,
        "resources": sorted(set(resources)),
        "aliases": sorted(set(aliases)),
        "profiles": sorted(set(profiles)),
    }


def emit_selector_index(board: BoardModel, out_dir: str) -> str:
    """Write the board selector index JSON and return the path."""
    out = Path(out_dir) / "reports" / "board_selectors.json"
    out.parent.mkdir(parents=True, exist_ok=True)

    index = build_selector_index(board)
    out.write_text(json.dumps(index, indent=2) + "\n", encoding="utf-8")
    return str(out)
