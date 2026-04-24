from socfw.build.full_pipeline import FullBuildPipeline


def test_validate_vendor_sdram_soc_passes_with_simple_bus_to_wishbone_support():
    result = FullBuildPipeline().validate("tests/golden/fixtures/vendor_sdram_soc/project.yaml")

    assert result.ok, [f"{d.code}: {d.message}" for d in result.diagnostics]
    assert result.value is not None
    assert "sdram_ctrl" in result.value.ip_catalog
