from __future__ import annotations


class CacheFormatter:
    def format_stage(self, name: str, hit: bool, note: str = "") -> str:
        state = "hit" if hit else "miss"
        if note:
            return f"[cache] {name}: {state} ({note})"
        return f"[cache] {name}: {state}"
