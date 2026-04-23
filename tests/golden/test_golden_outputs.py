import pytest
from pathlib import Path

from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline


def _read(p: Path) -> str:
    return p.read_text(encoding="utf-8")


FIXTURE_01 = Path("tests/golden/fixtures/blink_test_01/project.yaml")
EXPECTED_01 = Path("tests/golden/expected/blink_test_01")

FIXTURE_02 = Path("tests/golden/fixtures/blink_test_02/project.yaml")
EXPECTED_02 = Path("tests/golden/expected/blink_test_02")


@pytest.mark.golden
def test_blink_test_01_golden(tmp_path):
    templates = "socfw/templates"
    out_dir = tmp_path / "gen"

    pipeline = FullBuildPipeline(templates_dir=templates)
    result = pipeline.run(BuildRequest(project_file=str(FIXTURE_01), out_dir=str(out_dir)))

    assert result.ok, [str(d) for d in result.diagnostics]

    for rel in ["rtl/soc_top.sv", "hal/board.tcl"]:
        expected_file = EXPECTED_01 / rel
        if expected_file.exists():
            assert _read(out_dir / rel) == _read(expected_file), f"Golden mismatch: {rel}"


@pytest.mark.golden
def test_blink_test_02_golden(tmp_path):
    templates = "socfw/templates"
    out_dir = tmp_path / "gen"

    pipeline = FullBuildPipeline(templates_dir=templates)
    result = pipeline.run(BuildRequest(project_file=str(FIXTURE_02), out_dir=str(out_dir)))

    assert result.ok, [str(d) for d in result.diagnostics]

    for rel in ["rtl/soc_top.sv", "timing/soc_top.sdc", "reports/soc_graph.dot"]:
        expected_file = EXPECTED_02 / rel
        if expected_file.exists():
            assert _read(out_dir / rel) == _read(expected_file), f"Golden mismatch: {rel}"
