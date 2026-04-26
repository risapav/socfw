"""Integration tests: blink_test_02 project validates without errors."""
from pathlib import Path

import pytest

from socfw.build.full_pipeline import FullBuildPipeline
from socfw.build.context import BuildRequest

FIXTURE = Path("examples/blink_test_02/project.yaml")


@pytest.fixture(scope="module")
def build_result(tmp_path_factory):
    out_dir = tmp_path_factory.mktemp("blink02") / "gen"
    return FullBuildPipeline(templates_dir="socfw/templates").run(
        BuildRequest(project_file=str(FIXTURE), out_dir=str(out_dir))
    )


def test_build_ok(build_result):
    assert build_result.ok, [f"{d.code}: {d.message}" for d in build_result.diagnostics]


def test_no_errors(build_result):
    from socfw.core.diagnostics import Severity
    errors = [d for d in build_result.diagnostics if d.severity == Severity.ERROR]
    assert errors == []


def test_soc_top_sv_generated(build_result):
    sv_files = [a for a in build_result.artifacts.normalized() if a.path.endswith("soc_top.sv")]
    assert sv_files, "soc_top.sv not generated"


def test_board_tcl_generated(build_result):
    tcl_files = [a for a in build_result.artifacts.normalized() if a.path.endswith("board.tcl")]
    assert tcl_files, "board.tcl not generated"
