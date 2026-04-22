from pathlib import Path

from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline

FIXTURE = Path("tests/golden/fixtures/blink_test_02/project.yaml")


def test_blink02_soc_top_sv_has_clkpll(tmp_path):
    out_dir = tmp_path / "out"
    result = FullBuildPipeline(templates_dir="socfw/templates").run(
        BuildRequest(project_file=str(FIXTURE), out_dir=str(out_dir))
    )
    assert result.ok, [str(d) for d in result.diagnostics]

    sv = (out_dir / "rtl" / "soc_top.sv").read_text()
    assert "clkpll" in sv
    assert "blink_test" in sv


def test_blink02_sdc_has_generated_clock(tmp_path):
    out_dir = tmp_path / "out"
    result = FullBuildPipeline(templates_dir="socfw/templates").run(
        BuildRequest(project_file=str(FIXTURE), out_dir=str(out_dir))
    )
    assert result.ok, [str(d) for d in result.diagnostics]

    sdc = (out_dir / "timing" / "soc_top.sdc").read_text()
    assert "create_generated_clock" in sdc


def test_blink02_dot_graph(tmp_path):
    out_dir = tmp_path / "out"
    result = FullBuildPipeline(templates_dir="socfw/templates").run(
        BuildRequest(project_file=str(FIXTURE), out_dir=str(out_dir))
    )
    assert result.ok, [str(d) for d in result.diagnostics]

    dot = (out_dir / "reports" / "soc_graph.dot").read_text()
    assert "digraph soc" in dot
