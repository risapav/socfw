from __future__ import annotations


def resolve_feature_ref(ref: str, board_aliases: dict[str, str] | None = None) -> str | None:
    """
    Resolve a single feature ref to a canonical resource path (without 'board:' prefix).

    Supports:
      - board:onboard.leds           → onboard.leds
      - board:external.sdram.dq      → external.sdram.dq
      - board:@leds  (if aliases defined) → onboard.leds
    """
    if not ref.startswith("board:"):
        return None

    path = ref[len("board:"):]

    if path.startswith("@"):
        alias_key = path[1:]
        if board_aliases and alias_key in board_aliases:
            return board_aliases[alias_key]
        return None

    return path


class FeatureResolver:
    def __init__(self, board_aliases: dict[str, str] | None = None):
        self._aliases = board_aliases or {}

    def resolve(self, refs: list[str]) -> list[str]:
        """Resolve a list of feature refs to canonical paths."""
        resolved = []
        for ref in refs:
            path = resolve_feature_ref(ref, self._aliases)
            if path is not None:
                resolved.append(path)
        return resolved

    def resolve_one(self, ref: str) -> str | None:
        return resolve_feature_ref(ref, self._aliases)
