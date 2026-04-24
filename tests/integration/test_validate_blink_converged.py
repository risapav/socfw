from socfw.build.full_pipeline import FullBuildPipeline

FIXTURE = "tests/golden/fixtures/blink_converged/project.yaml"


def test_validate_blink_converged():
    result = FullBuildPipeline().validate(FIXTURE)
    assert result.ok, [str(d) for d in result.diagnostics]
    assert result.value is not None
    assert result.value.project.name == "blink_converged"
    assert result.value.board.board_id == "qmtech_ep4ce55"
    assert "blink_test" in result.value.ip_catalog
