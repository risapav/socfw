from socfw.build.full_pipeline import FullBuildPipeline

FIXTURE = "tests/golden/fixtures/vendor_pll_soc/project.yaml"


def test_validate_vendor_pll_soc():
    result = FullBuildPipeline().validate(FIXTURE)

    assert result.ok, [f"{d.code}: {d.message}" for d in result.diagnostics]
    assert result.value is not None
    assert "sys_pll" in result.value.ip_catalog
    assert result.value.ip_catalog["sys_pll"].vendor_info is not None
    assert result.value.ip_catalog["sys_pll"].vendor_info.vendor == "intel"
