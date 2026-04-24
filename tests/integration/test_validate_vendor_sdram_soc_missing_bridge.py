from socfw.build.full_pipeline import FullBuildPipeline


def test_validate_reports_missing_bridge_for_unknown_protocol():
    result = FullBuildPipeline().validate("tests/golden/fixtures/bad_bridge_missing/project.yaml")

    assert not result.ok
    codes = {d.code for d in result.diagnostics}
    assert "BRG001" in codes


def test_validate_vendor_sdram_soc_bridge_is_known():
    result = FullBuildPipeline().validate("tests/golden/fixtures/vendor_sdram_soc/project.yaml")

    assert result.ok, [f"{d.code}: {d.message}" for d in result.diagnostics]
    codes = {d.code for d in result.diagnostics}
    assert "BRG001" not in codes
