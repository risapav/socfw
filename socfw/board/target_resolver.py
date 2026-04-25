from __future__ import annotations

from socfw.board.alias_resolver import AliasResolver
from socfw.board.profile_resolver import ProfileResolver


class BoardTargetResolver:
    """Unified resolver for board targets: aliases, profiles, and derived resources."""

    def __init__(self, board):
        self._board = board
        self._alias_res = AliasResolver(board.aliases)
        self._profile_res = ProfileResolver(board.profiles)

    def resolve(self, ref: str) -> tuple[str, bool]:
        """
        Resolve a board: ref, expanding @alias.
        Returns (resolved_ref, is_valid_resource).
        """
        resolved, _diags = self._alias_res.resolve_ref(ref)
        if resolved.startswith("board:"):
            path = resolved[len("board:"):]
            is_valid = self._path_exists(path)
            return resolved, is_valid
        return resolved, False

    def resolve_feature_profile(self, profile_name: str) -> list[str] | None:
        """Resolve a profile name to a list of board: refs."""
        return self._profile_res.resolve(profile_name)

    def expand_features(self, profile: str | None, use: list[str]) -> list[str]:
        """Expand profile + explicit use into resolved board: refs."""
        refs = self._profile_res.expand_features(profile, use)
        resolved = []
        for ref in refs:
            r, _diags = self._alias_res.resolve_ref(ref)
            resolved.append(r)
        return resolved

    def _path_exists(self, path: str) -> bool:
        """Check if a dotted board resource path exists."""
        cur = self._board.resources
        for part in path.split("."):
            if not isinstance(cur, dict) or part not in cur:
                # Also check onboard
                if path.startswith("onboard."):
                    subpath = path[len("onboard."):]
                    parts = subpath.split(".", 1)
                    if parts[0] in self._board.onboard:
                        return True
                return False
            cur = cur[part]
        return True

    def list_resource_paths(self) -> list[str]:
        """Return all bindable board: resource paths."""
        paths = []
        self._collect_paths(self._board.resources, "", paths)
        for key in self._board.onboard:
            paths.append(f"board:onboard.{key}")
        return sorted(set(paths))

    def _collect_paths(self, node: dict, prefix: str, paths: list[str]) -> None:
        if not isinstance(node, dict):
            return
        if "kind" in node and "top_name" in node:
            paths.append(f"board:{prefix}" if prefix else "")
            return
        for key, val in node.items():
            cur = f"{prefix}.{key}" if prefix else key
            if isinstance(val, dict):
                if "kind" in val:
                    paths.append(f"board:{cur}")
                else:
                    self._collect_paths(val, cur, paths)
