from pathlib import Path

from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _assert_same(generated: Path, expected: Path):
    assert generated.exists(), f"Missing generated file: {generated}"
    assert expected.exists(), f"Missing expected file: {expected}"
    assert _read(generated) == _read(expected)


def test_vendor_sdram_soc_golden(tmp_path):
    out_dir = tmp_path / "out"

    result = FullBuildPipeline().run(
        BuildRequest(
            project_file="tests/golden/fixtures/vendor_sdram_soc/project.yaml",
            out_dir=str(out_dir),
        )
    )

    assert result.ok, [f"{d.code}: {d.message}" for d in result.diagnostics]

    expected_root = Path("tests/golden/expected/vendor_sdram_soc")

    _assert_same(out_dir / "rtl" / "soc_top.sv", expected_root / "rtl" / "soc_top.sv")
    _assert_same(out_dir / "hal" / "files.tcl", expected_root / "hal" / "files.tcl")
    _assert_same(out_dir / "reports" / "bridge_summary.txt", expected_root / "reports" / "bridge_summary.txt")
    _assert_same(out_dir / "reports" / "build_summary.md", expected_root / "reports" / "build_summary.md")

    timing_expected = expected_root / "timing" / "soc_top.sdc"
    timing_generated = out_dir / "timing" / "soc_top.sdc"
    if timing_expected.exists():
        _assert_same(timing_generated, timing_expected)
