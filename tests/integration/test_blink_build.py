import pytest
from pathlib import Path

from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline

FIXTURE = Path("tests/golden/fixtures/blink_test_01/project.yaml")


@pytest.mark.skipif(not FIXTURE.exists(), reason="golden fixture not present")
def test_blink_build(tmp_path):
    templates = "socfw/templates"
    out_dir = tmp_path / "out"

    pipeline = FullBuildPipeline(templates_dir=templates)
    result = pipeline.run(BuildRequest(project_file=str(FIXTURE), out_dir=str(out_dir)))

    assert result.ok
    assert (out_dir / "rtl" / "soc_top.sv").exists()
    assert (out_dir / "hal" / "board.tcl").exists()
    assert (out_dir / "reports" / "build_report.json").exists()
