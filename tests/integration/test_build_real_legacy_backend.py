from pathlib import Path

import pytest

from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline

FIXTURE = Path("tests/golden/fixtures/blink_test_01/project.yaml")


@pytest.mark.skipif(not FIXTURE.exists(), reason="blink_test_01 fixture not found")
def test_build_runs_real_legacy_backend_and_emits_outputs(tmp_path):
    out_dir = tmp_path / "out"
    pipeline = FullBuildPipeline()

    result = pipeline.run(BuildRequest(
        project_file=str(FIXTURE),
        out_dir=str(out_dir),
    ))

    assert result.ok, [str(d) for d in result.diagnostics]
    assert (out_dir / "rtl" / "soc_top.sv").exists()
    assert (out_dir / "hal" / "board.tcl").exists()
