from __future__ import annotations

import json
from dataclasses import asdict
from pathlib import Path

from socfw.build.cache_model import CacheManifest, CacheStageRecord


class CacheStore:
    def __init__(self, out_dir: str) -> None:
        self.root = Path(out_dir) / ".socfw_cache"
        self.root.mkdir(parents=True, exist_ok=True)
        self.manifest_file = self.root / "cache_manifest.json"

    def load(self) -> CacheManifest:
        if not self.manifest_file.exists():
            return CacheManifest()

        data = json.loads(self.manifest_file.read_text(encoding="utf-8"))
        manifest = CacheManifest()
        for name, rec in data.get("stages", {}).items():
            manifest.stages[name] = CacheStageRecord(**rec)
        return manifest

    def save(self, manifest: CacheManifest) -> None:
        payload = {"stages": {k: asdict(v) for k, v in manifest.stages.items()}}
        self.manifest_file.write_text(json.dumps(payload, indent=2), encoding="utf-8")
