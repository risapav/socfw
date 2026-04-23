from __future__ import annotations

import json
from pathlib import Path

from socfw.config.board_schema import BoardConfigSchema
from socfw.config.project_schema import ProjectConfigSchema
from socfw.config.ip_schema import IpConfigSchema
from socfw.config.cpu_schema import CpuDescriptorSchema
from socfw.config.timing_schema import TimingDocumentSchema


class SchemaExporter:
    def export_all(self, out_dir: str) -> list[str]:
        out = Path(out_dir)
        out.mkdir(parents=True, exist_ok=True)

        schemas = {
            "board.schema.json": BoardConfigSchema.model_json_schema(),
            "project.schema.json": ProjectConfigSchema.model_json_schema(),
            "ip.schema.json": IpConfigSchema.model_json_schema(),
            "cpu.schema.json": CpuDescriptorSchema.model_json_schema(),
            "timing.schema.json": TimingDocumentSchema.model_json_schema(),
        }

        paths: list[str] = []
        for name, schema in schemas.items():
            fp = out / name
            fp.write_text(json.dumps(schema, indent=2), encoding="utf-8")
            paths.append(str(fp))

        return paths
