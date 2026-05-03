from pathlib import Path

from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline

FIXTURE = Path("tests/golden/fixtures/blink_test_01/project.yaml")


def test_blink01_soc_top_sv(tmp_path):
    out_dir = tmp_path / "out"
    result = FullBuildPipeline(templates_dir="socfw/templates").run(
        BuildRequest(project_file=str(FIXTURE), out_dir=str(out_dir))
    )
    assert result.ok, [str(d) for d in result.diagnostics]

    sv = (out_dir / "rtl" / "soc_top.sv").read_text()
    assert "module soc_top" in sv
    assert "blink_test" in sv


def test_blink01_board_tcl(tmp_path):
    out_dir = tmp_path / "out"
    result = FullBuildPipeline(templates_dir="socfw/templates").run(
        BuildRequest(project_file=str(FIXTURE), out_dir=str(out_dir))
    )
    assert result.ok, [str(d) for d in result.diagnostics]

    tcl = (out_dir / "hal" / "board.tcl").read_text()
    assert "ONB_LEDS" in tcl


def test_blink01_build_report_json(tmp_path):
    out_dir = tmp_path / "out"
    result = FullBuildPipeline(templates_dir="socfw/templates").run(
        BuildRequest(project_file=str(FIXTURE), out_dir=str(out_dir))
    )
    assert result.ok, [str(d) for d in result.diagnostics]
    assert (out_dir / "reports" / "build_provenance.json").exists()
