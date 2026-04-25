from __future__ import annotations

from dataclasses import dataclass, field

from socfw.board.alias_resolver import AliasResolver
from socfw.board.profile_resolver import ProfileResolver
from socfw.board.resource_tree import iter_resource_leaves
from socfw.model.board import BoardModel


@dataclass
class SelectedResources:
    """Fully expanded set of board resource paths selected by project features."""
    paths: list[str] = field(default_factory=list)

    def __contains__(self, path: str) -> bool:
        return path in self.paths

    def __iter__(self):
        return iter(self.paths)

    def __len__(self) -> int:
        return len(self.paths)


def expand_features(
    board: BoardModel,
    profile: str | None,
    use: list[str],
) -> SelectedResources:
    """
    Expand project features into a flat selected resource path list.

    Each board: ref is expanded to all leaf resource paths it covers.
    Aliases are resolved before expansion.
    Returns paths without the 'board:' prefix, e.g. 'external.sdram.addr'.
    """
    alias_res = AliasResolver(board.aliases)
    profile_res = ProfileResolver(board.profiles)

    raw_refs = profile_res.expand_features(profile, use)

    resolved_refs: list[str] = []
    for ref in raw_refs:
        r, _diags = alias_res.resolve_ref(ref)
        resolved_refs.append(r)

    paths: list[str] = []
    seen: set[str] = set()

    for ref in resolved_refs:
        if not ref.startswith("board:"):
            continue
        path = ref[len("board:"):]

        if path.startswith("onboard."):
            sub = path[len("onboard."):]
            parts = sub.split(".", 1)
            res_key = parts[0]
            if res_key in board.onboard:
                _add(path, paths, seen)
            continue

        if path.startswith("external."):
            sub = path[len("external."):]
            external = board.resources.get("external") or {}
            parts = sub.split(".")
            cur = external
            valid = True
            for p in parts:
                if not isinstance(cur, dict) or p not in cur:
                    valid = False
                    break
                cur = cur[p]

            if valid and isinstance(cur, dict):
                if "kind" in cur:
                    _add(path, paths, seen)
                else:
                    # Expand to all leaves
                    for leaf_path, _ in iter_resource_leaves(external, sub):
                        _add(f"external.{leaf_path}", paths, seen)

    return SelectedResources(paths=paths)


def _add(path: str, paths: list[str], seen: set[str]) -> None:
    if path not in seen:
        seen.add(path)
        paths.append(path)
