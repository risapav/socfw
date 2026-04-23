from __future__ import annotations

from pathlib import Path

from socfw.config.board_schema import BoardConfigSchema
from socfw.config.project_schema import ProjectConfigSchema
from socfw.config.ip_schema import IpConfigSchema
from socfw.config.cpu_schema import CpuDescriptorSchema
from socfw.config.timing_schema import TimingDocumentSchema
from socfw.tools.schema_docgen import SchemaDocGenerator
from socfw.tools.example_catalog import ExampleCatalogGenerator


class ConfigDocsExporter:
    def __init__(self) -> None:
        self.docgen = SchemaDocGenerator()
        self.examples = ExampleCatalogGenerator()

    def export_all(self, out_dir: str) -> list[str]:
        out = Path(out_dir)
        out.mkdir(parents=True, exist_ok=True)

        targets = [
            ("Board config reference", BoardConfigSchema.model_json_schema(), out / "config_board.md"),
            ("Project config reference", ProjectConfigSchema.model_json_schema(), out / "config_project.md"),
            ("IP descriptor reference", IpConfigSchema.model_json_schema(), out / "config_ip.md"),
            ("CPU descriptor reference", CpuDescriptorSchema.model_json_schema(), out / "config_cpu.md"),
            ("Timing config reference", TimingDocumentSchema.model_json_schema(), out / "config_timing.md"),
        ]

        paths: list[str] = []
        for title, schema, fp in targets:
            paths.append(
                self.docgen.generate_markdown(
                    title=title,
                    schema=schema,
                    out_file=str(fp),
                )
            )

        fixtures_root = "tests/golden/fixtures"
        if Path(fixtures_root).exists():
            paths.append(
                self.examples.generate(
                    fixtures_root=fixtures_root,
                    out_file=str(out / "examples_catalog.md"),
                )
            )

        return paths
