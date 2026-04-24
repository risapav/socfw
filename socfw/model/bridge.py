from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class BridgeSupport:
    src_protocol: str
    dst_protocol: str
    bridge_kind: str
    notes: str | None = None
