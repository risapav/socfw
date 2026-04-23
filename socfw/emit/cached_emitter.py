from __future__ import annotations

from pathlib import Path

from socfw.tools.fingerprint import fingerprint_files, fingerprint_obj


class CachedEmitterMixin:
    emitter_version = "v1"

    def emitter_fingerprint(self, *, ir, template_files: list[str] | None = None) -> str:
        payload = {
            "emitter_version": self.emitter_version,
            "ir": ir,
            "templates": fingerprint_files(template_files or []),
        }
        return fingerprint_obj(payload)

    def outputs_exist(self, outputs: list[str]) -> bool:
        return all(Path(p).exists() for p in outputs)
