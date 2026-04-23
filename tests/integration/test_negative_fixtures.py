from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline


def _build(fixture_name: str, tmp_path):
    project = f"tests/golden/fixtures/{fixture_name}/project.yaml"
    result = FullBuildPipeline(templates_dir="socfw/templates").run(
        BuildRequest(project_file=project, out_dir=str(tmp_path / "out"))
    )
    return result


def test_bad_overlap_soc_fails_with_bus003(tmp_path):
    result = _build("bad_overlap_soc", tmp_path)
    assert not result.ok
    codes = {d.code for d in result.diagnostics}
    assert "BUS003" in codes


def test_bad_cpu_type_fails_with_cpu001(tmp_path):
    result = _build("bad_cpu_type", tmp_path)
    assert not result.ok
    codes = {d.code for d in result.diagnostics}
    assert "CPU001" in codes


def test_bad_bridge_missing_fails_with_brg001(tmp_path):
    result = _build("bad_bridge_missing", tmp_path)
    assert not result.ok
    codes = {d.code for d in result.diagnostics}
    assert "BRG001" in codes


def test_bad_board_ref_fails_with_brd002(tmp_path):
    result = _build("bad_board_ref", tmp_path)
    assert not result.ok
    codes = {d.code for d in result.diagnostics}
    assert "BRD002" in codes
