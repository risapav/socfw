from pathlib import Path

from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline

FIXTURE = Path("tests/golden/fixtures/soc_led_test/project.yaml")


def test_soc_led_build_ok(tmp_path):
    out_dir = tmp_path / "out"
    result = FullBuildPipeline(templates_dir="socfw/templates").run(
        BuildRequest(project_file=str(FIXTURE), out_dir=str(out_dir))
    )
    assert result.ok, [str(d) for d in result.diagnostics]


def test_soc_led_soc_top_sv(tmp_path):
    out_dir = tmp_path / "out"
    result = FullBuildPipeline(templates_dir="socfw/templates").run(
        BuildRequest(project_file=str(FIXTURE), out_dir=str(out_dir))
    )
    assert result.ok, [str(d) for d in result.diagnostics]

    sv = (out_dir / "rtl" / "soc_top.sv").read_text()
    assert "module soc_top" in sv
    assert "gpio" in sv


def test_soc_led_soc_map_h(tmp_path):
    out_dir = tmp_path / "out"
    result = FullBuildPipeline(templates_dir="socfw/templates").run(
        BuildRequest(project_file=str(FIXTURE), out_dir=str(out_dir), legacy_backend=True)
    )
    assert result.ok, [str(d) for d in result.diagnostics]

    h = (out_dir / "sw" / "soc_map.h").read_text()
    assert "GPIO0_BASE" in h or "gpio0" in h.lower()


def test_soc_led_graph(tmp_path):
    out_dir = tmp_path / "out"
    result = FullBuildPipeline(templates_dir="socfw/templates").run(
        BuildRequest(project_file=str(FIXTURE), out_dir=str(out_dir), legacy_backend=True)
    )
    assert result.ok, [str(d) for d in result.diagnostics]

    dot = (out_dir / "reports" / "soc_graph.dot").read_text()
    assert "digraph soc" in dot
