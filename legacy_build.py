from __future__ import annotations

from pathlib import Path

from socfw.utils.deprecation import print_legacy_warning


def build_legacy(project_file: str, out_dir: str, system=None, planned_bridges=None) -> list[str]:
    print_legacy_warning()

    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)

    return _collect_generated(out_dir)


def _collect_generated(out_dir: str) -> list[str]:
    root = Path(out_dir)
    found = []
    for sub in ["rtl", "hal", "timing", "sw", "docs", "reports"]:
        sp = root / sub
        if sp.exists():
            for fp in sorted(sp.rglob("*")):
                if fp.is_file():
                    found.append(str(fp))
    return sorted(dict.fromkeys(found))
