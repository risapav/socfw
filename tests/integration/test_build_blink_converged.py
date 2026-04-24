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

    assert result.ok, [f"{d.code}: {d.message}" for d in result.diagnostics]

    rtl = out_dir / "rtl" / "soc_top.sv"
    board_tcl = out_dir / "hal" / "board.tcl"
    timing_sdc = out_dir / "timing" / "soc_top.sdc"

    assert rtl.exists()
    assert board_tcl.exists()
    assert timing_sdc.exists()

    rtl_text = rtl.read_text(encoding="utf-8")
    assert "module soc_top" in rtl_text
    assert "blink_test" in rtl_text
    assert "ONB_LEDS" in rtl_text
    assert "blink_test blink_test" in rtl_text
