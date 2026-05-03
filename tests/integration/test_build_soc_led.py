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


def test_soc_led_board_bindings(tmp_path):
    out_dir = tmp_path / "out"
    result = FullBuildPipeline(templates_dir="socfw/templates").run(
        BuildRequest(project_file=str(FIXTURE), out_dir=str(out_dir))
    )
    assert result.ok, [str(d) for d in result.diagnostics]

    md = (out_dir / "reports" / "board_bindings.md").read_text()
    assert "onboard.leds" in md or "ONB_LEDS" in md


def test_soc_led_build_summary(tmp_path):
    out_dir = tmp_path / "out"
    result = FullBuildPipeline(templates_dir="socfw/templates").run(
        BuildRequest(project_file=str(FIXTURE), out_dir=str(out_dir))
    )
    assert result.ok, [str(d) for d in result.diagnostics]

    summary = (out_dir / "reports" / "build_summary.md").read_text()
    assert "soc_led" in summary.lower() or "led" in summary.lower()
