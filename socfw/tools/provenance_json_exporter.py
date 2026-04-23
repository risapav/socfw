from __future__ import annotations

import json
from dataclasses import asdict
from pathlib import Path


class ProvenanceJsonExporter:
    def export(self, provenance, out_file: str) -> str:
        fp = Path(out_file)
        fp.parent.mkdir(parents=True, exist_ok=True)
        fp.write_text(json.dumps(asdict(provenance), indent=2), encoding="utf-8")
        return str(fp)
