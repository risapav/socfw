import pytest
from pathlib import Path

from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline


def _read(p: Path) -> str:
    return p.read_text(encoding="utf-8")


FIXTURE_01 = Path("tests/golden/fixtures/blink_test_01/project.yaml")
EXPECTED_01 = Path("tests/golden/expected/blink_test_01")


@pytest.mark.golden
@pytest.mark.skipif(not FIXTURE_01.exists(), reason="golden fixture not present")
def test_blink_test_01_golden(tmp_path):
    templates = "socfw/templates"
    out_dir = tmp_path / "gen"

    pipeline = FullBuildPipeline(templates_dir=templates)
    result = pipeline.run(BuildRequest(project_file=str(FIXTURE_01), out_dir=str(out_dir)))

    assert result.ok

    for rel in ["rtl/soc_top.sv", "hal/board.tcl", "reports/build_report.md"]:
        expected_file = EXPECTED_01 / rel
        if expected_file.exists():
            assert _read(out_dir / rel) == _read(expected_file), f"Golden mismatch: {rel}"
