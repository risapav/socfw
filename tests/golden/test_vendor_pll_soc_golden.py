from pathlib import Path

from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline

FIXTURE = "tests/golden/fixtures/vendor_pll_soc/project.yaml"
EXPECTED = Path("tests/golden/expected/vendor_pll_soc")


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _assert_same(generated: Path, expected: Path):
    assert generated.exists(), f"Missing generated file: {generated}"
    assert expected.exists(), f"Missing expected file: {expected}"
    assert _read(generated) == _read(expected)


def test_vendor_pll_soc_golden(tmp_path):
    out_dir = tmp_path / "out"

    result = FullBuildPipeline().run(
        BuildRequest(
            project_file=FIXTURE,
            out_dir=str(out_dir),
        )
    )

    assert result.ok, [f"{d.code}: {d.message}" for d in result.diagnostics]

    _assert_same(out_dir / "rtl" / "soc_top.sv", EXPECTED / "rtl" / "soc_top.sv")
    _assert_same(out_dir / "hal" / "board.tcl", EXPECTED / "hal" / "board.tcl")
    _assert_same(out_dir / "files.tcl", EXPECTED / "files.tcl")
    _assert_same(out_dir / "timing" / "soc_top.sdc", EXPECTED / "timing" / "soc_top.sdc")
    _assert_same(out_dir / "reports" / "build_summary.md", EXPECTED / "reports" / "build_summary.md")
