from socfw.tools.schema_exporter import SchemaExporter
from socfw.tools.config_docs_exporter import ConfigDocsExporter


def test_schema_export(tmp_path):
    out = tmp_path / "schema"
    paths = SchemaExporter().export_all(str(out))

    assert len(paths) >= 5
    assert (out / "board.schema.json").exists()
    assert (out / "project.schema.json").exists()
    assert (out / "ip.schema.json").exists()
    assert (out / "cpu.schema.json").exists()
    assert (out / "timing.schema.json").exists()


def test_docs_export(tmp_path):
    out = tmp_path / "docs"
    paths = ConfigDocsExporter().export_all(str(out))

    assert len(paths) >= 5
    assert (out / "config_board.md").exists()
    assert (out / "config_project.md").exists()
    assert (out / "config_ip.md").exists()
    assert (out / "config_cpu.md").exists()
    assert (out / "config_timing.md").exists()
