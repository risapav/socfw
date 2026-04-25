from __future__ import annotations


class ProfileResolver:
    def __init__(self, board_profiles: dict[str, list[str]]):
        self._profiles = board_profiles

    def resolve(self, profile_name: str) -> list[str] | None:
        """Return list of resource paths for a profile, or None if not found."""
        use_list = self._profiles.get(profile_name)
        if use_list is None:
            return None
        return [f"board:{path}" if not path.startswith("board:") else path for path in use_list]

    def expand_features(self, profile: str | None, use: list[str]) -> list[str]:
        """Combine profile use list with explicit use list, deduplicating."""
        result = list(use)
        if profile:
            profile_refs = self.resolve(profile)
            if profile_refs:
                for ref in profile_refs:
                    if ref not in result:
                        result.append(ref)
        return result
