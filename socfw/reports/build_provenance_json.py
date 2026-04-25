from __future__ import annotations

import json
from dataclasses import asdict, is_dataclass
from pathlib import Path


class BuildProvenanceJsonReport:
    def build(self, provenance) -> str:
        if is_dataclass(provenance):
            data = asdict(provenance)
        else:
            data = dict(provenance)

        return json.dumps(
            data,
            indent=2,
            sort_keys=True,
            ensure_ascii=False,
        ) + "\n"

    def write(self, out_dir: str, provenance) -> str:
        reports_dir = Path(out_dir) / "reports"
        reports_dir.mkdir(parents=True, exist_ok=True)

        out_file = reports_dir / "build_provenance.json"
        out_file.write_text(self.build(provenance), encoding="utf-8")
        return str(out_file)
