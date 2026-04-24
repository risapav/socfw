from socfw.build.full_pipeline import FullBuildPipeline

FIXTURE = "tests/golden/fixtures/pll_converged/project.yaml"


def test_validate_pll_converged():
    result = FullBuildPipeline().validate(FIXTURE)

    assert result.ok, [f"{d.code}: {d.message}" for d in result.diagnostics]
    assert result.value is not None
    assert result.value.project.name == "pll_converged"
    assert result.value.board.board_id == "qmtech_ep4ce55"
    assert "clkpll" in result.value.ip_catalog
    assert "blink_test" in result.value.ip_catalog
    assert result.value.timing is not None
    assert len(result.value.timing.generated_clocks) == 1
    assert len(result.value.timing.false_paths) == 1
