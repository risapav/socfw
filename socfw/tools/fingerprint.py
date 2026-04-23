from __future__ import annotations

import dataclasses
import hashlib
import json
from pathlib import Path
from typing import Any


def canonicalize(obj: Any) -> Any:
    if dataclasses.is_dataclass(obj):
        return canonicalize(dataclasses.asdict(obj))
    if isinstance(obj, dict):
        return {str(k): canonicalize(v) for k, v in sorted(obj.items(), key=lambda kv: str(kv[0]))}
    if isinstance(obj, (list, tuple)):
        return [canonicalize(x) for x in obj]
    if isinstance(obj, Path):
        return str(obj)
    return obj


def stable_json(obj: Any) -> str:
    return json.dumps(
        canonicalize(obj),
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    )


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def fingerprint_obj(obj: Any) -> str:
    return sha256_text(stable_json(obj))


def fingerprint_files(paths: list[str]) -> str:
    h = hashlib.sha256()
    for p in sorted(paths):
        fp = Path(p)
        h.update(str(fp).encode("utf-8"))
        if fp.exists():
            h.update(fp.read_bytes())
        else:
            h.update(b"<missing>")
    return h.hexdigest()
