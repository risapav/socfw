from __future__ import annotations

import time
from contextlib import contextmanager


@contextmanager
def timed():
    start = time.perf_counter()
    box: dict[str, float] = {"duration_ms": 0.0}
    try:
        yield box
    finally:
        box["duration_ms"] = (time.perf_counter() - start) * 1000.0
