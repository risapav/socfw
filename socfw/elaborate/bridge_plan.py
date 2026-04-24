from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class PlannedBridge:
    instance: str
    kind: str
    src_protocol: str
    dst_protocol: str
    target_module: str
    fabric: str
    rtl_file: str
