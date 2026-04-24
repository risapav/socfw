from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline

FIXTURE = "tests/golden/fixtures/blink_converged/project.yaml"


def test_build_blink_converged(tmp_path):
    out_dir = tmp_path / "out"

    result = FullBuildPipeline().run(
        BuildRequest(
            project_file=FIXTURE,
            out_dir=str(out_dir),
        )
    )

    assert result.ok, [str(d) for d in result.diagnostics]
    assert (out_dir / "rtl" / "soc_top.sv").exists()
    assert (out_dir / "hal" / "board.tcl").exists()
