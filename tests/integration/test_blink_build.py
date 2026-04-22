from pathlib import Path

import pytest

from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline

FIXTURE_01 = Path("tests/golden/fixtures/blink_test_01/project.yaml")
FIXTURE_02 = Path("tests/golden/fixtures/blink_test_02/project.yaml")


def test_blink_test_01_build(tmp_path):
    out_dir = tmp_path / "out"
    pipeline = FullBuildPipeline(templates_dir="socfw/templates")
    result = pipeline.run(BuildRequest(project_file=str(FIXTURE_01), out_dir=str(out_dir)))

    assert result.ok, [str(d) for d in result.diagnostics]
    assert (out_dir / "rtl" / "soc_top.sv").exists()
    assert (out_dir / "hal" / "board.tcl").exists()
    assert (out_dir / "reports" / "build_report.json").exists()
    assert (out_dir / "reports" / "build_report.md").exists()
    assert (out_dir / "reports" / "soc_graph.dot").exists()


def test_blink_test_02_build(tmp_path):
    out_dir = tmp_path / "out"
    pipeline = FullBuildPipeline(templates_dir="socfw/templates")
    result = pipeline.run(BuildRequest(project_file=str(FIXTURE_02), out_dir=str(out_dir)))

    assert result.ok, [str(d) for d in result.diagnostics]
    assert (out_dir / "rtl" / "soc_top.sv").exists()
    assert (out_dir / "timing" / "soc_top.sdc").exists()
    assert (out_dir / "reports" / "soc_graph.dot").exists()
