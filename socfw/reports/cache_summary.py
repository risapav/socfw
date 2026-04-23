from __future__ import annotations


class CacheSummary:
    def summarize(self, provenance) -> dict[str, int]:
        out: dict[str, int] = {"hit": 0, "miss": 0, "always": 0, "failed": 0}
        for s in provenance.stages:
            out[s.status] = out.get(s.status, 0) + 1
        return out
