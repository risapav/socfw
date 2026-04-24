from socfw.build.full_pipeline import FullBuildPipeline


def test_validate_vendor_sdram_soc():
    result = FullBuildPipeline().validate("tests/golden/fixtures/vendor_sdram_soc/project.yaml")

    assert result.ok, [f"{d.code}: {d.message}" for d in result.diagnostics]
    assert result.value is not None

    board = result.value.board
    assert board.resolve_resource_path("external.sdram.addr") is not None
    assert board.resolve_resource_path("external.sdram.dq") is not None
    assert board.resolve_resource_path("external.sdram.clk") is not None

    assert result.value.cpu is not None
    assert result.value.cpu_desc() is not None
