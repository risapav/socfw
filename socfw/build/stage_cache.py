from __future__ import annotations

from socfw.build.cache_model import CacheStageRecord
from socfw.build.cache_store import CacheStore


class StageCache:
    def __init__(self, store: CacheStore) -> None:
        self.store = store
        self.manifest = store.load()

    def check(self, stage_name: str, fingerprint: str) -> bool:
        rec = self.manifest.stages.get(stage_name)
        return rec is not None and rec.fingerprint == fingerprint

    def update(
        self,
        stage_name: str,
        fingerprint: str,
        *,
        inputs: list[str] | None = None,
        outputs: list[str] | None = None,
        hit: bool = False,
        note: str = "",
    ) -> None:
        self.manifest.stages[stage_name] = CacheStageRecord(
            name=stage_name,
            fingerprint=fingerprint,
            inputs=inputs or [],
            outputs=outputs or [],
            hit=hit,
            note=note,
        )
        self.store.save(self.manifest)
