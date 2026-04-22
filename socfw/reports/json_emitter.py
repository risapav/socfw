from __future__ import annotations

import json
from dataclasses import asdict
from pathlib import Path

from socfw.reports.model import BuildReport


class JsonReportEmitter:
    def emit(self, report: BuildReport, out_dir: str) -> str:
        out = Path(out_dir) / "reports" / "build_report.json"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(asdict(report), indent=2), encoding="utf-8")
        return str(out)
