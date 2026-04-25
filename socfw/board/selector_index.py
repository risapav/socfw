from __future__ import annotations

from dataclasses import dataclass, field

from socfw.board.resource_tree import iter_resource_leaves
from socfw.model.board import BoardModel


@dataclass
class BoardSelectorIndex:
    board_id: str
    resources: list[str] = field(default_factory=list)
    aliases: list[str] = field(default_factory=list)
    profiles: list[str] = field(default_factory=list)
    connectors: list[str] = field(default_factory=list)


def build_selector_index(board: BoardModel) -> BoardSelectorIndex:
    """Build a complete board selector index for editor support and diagnostics."""
    resources: list[str] = []
    aliases: list[str] = []
    profiles: list[str] = []
    connectors: list[str] = []

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
    for key in external:
        for leaf_path, _ in iter_resource_leaves(external, key):
            resources.append(f"board:external.{leaf_path}")

    # Connectors (displayable but not bindable)
    raw_connectors = board.resources.get("connectors") or {}
    _collect_connector_paths(raw_connectors, "board:connectors", connectors)

    # Aliases
    for alias_key in board.aliases:
        aliases.append(f"board:@{alias_key}")

    # Profiles
    for profile_name in board.profiles:
        profiles.append(profile_name)

    return BoardSelectorIndex(
        board_id=board.board_id,
        resources=sorted(set(resources)),
        aliases=sorted(set(aliases)),
        profiles=sorted(set(profiles)),
        connectors=sorted(set(connectors)),
    )


def _collect_connector_paths(node: dict, prefix: str, out: list[str]) -> None:
    """Recursively collect all connector paths."""
    for key, val in node.items():
        path = f"{prefix}.{key}"
        out.append(path)
        if isinstance(val, dict) and not _is_connector_leaf(val):
            _collect_connector_paths(val, path, out)


def _is_connector_leaf(node: dict) -> bool:
    """Return True if node is a physical connector definition (has pins)."""
    return "pins" in node or "pin" in node
