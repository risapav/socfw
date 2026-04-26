from pathlib import Path

from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline

FIXTURE = "tests/golden/fixtures/blink_test_01/project.yaml"
EXPECTED = Path("tests/golden/expected/blink_test_01")


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _assert_same(generated: Path, expected: Path):
    assert generated.exists(), f"Missing generated file: {generated}"
    assert expected.exists(), f"Missing expected file: {expected}"
    assert _read(generated) == _read(expected)


def test_blink_test_01_golden(tmp_path):
    out_dir = tmp_path / "out"

    result = FullBuildPipeline(templates_dir="socfw/templates").run(
        BuildRequest(
            project_file=FIXTURE,
            out_dir=str(out_dir),
        )
    )

    assert result.ok, [f"{d.code}: {d.message}" for d in result.diagnostics]

    _assert_same(out_dir / "rtl" / "soc_top.sv", EXPECTED / "rtl" / "soc_top.sv")
    _assert_same(out_dir / "hal" / "board.tcl", EXPECTED / "hal" / "board.tcl")
    _assert_same(out_dir / "hal" / "files.tcl", EXPECTED / "hal" / "files.tcl")
    _assert_same(out_dir / "timing" / "soc_top.sdc", EXPECTED / "timing" / "soc_top.sdc")

    rtl = _read(out_dir / "rtl" / "soc_top.sv")
    assert "input wire RESET_N" in rtl, "RESET_N must be present (reset port consumed by blink_test)"
    assert ".rst_n(reset_n)" in rtl, "rst_n must be connected to internal reset_n"

    board_tcl = _read(out_dir / "hal" / "board.tcl")
    assert 'IO_STANDARD "3.3-V LVTTL" -to SYS_CLK' in board_tcl
    assert 'IO_STANDARD "3.3-V LVTTL" -to RESET_N' in board_tcl
    assert 'IO_STANDARD "3.3-V LVTTL" -to ONB_LEDS' in board_tcl

    files_tcl = _read(out_dir / "hal" / "files.tcl")
    sdc_count = files_tcl.count("soc_top.sdc")
    assert sdc_count <= 1, f"soc_top.sdc appears {sdc_count} times in files.tcl (must not duplicate)"
