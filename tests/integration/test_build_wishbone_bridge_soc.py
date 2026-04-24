from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline


def test_build_wishbone_bridge_soc(tmp_path):
    templates = "socfw/templates"
    project = "tests/golden/fixtures/wishbone_bridge_soc/project.yaml"
    out_dir = tmp_path / "out"

    pipeline = FullBuildPipeline(templates_dir=templates)
    result = pipeline.run(BuildRequest(project_file=project, out_dir=str(out_dir)))

    assert result.ok, [str(d) for d in result.diagnostics]

    rtl = (out_dir / "rtl" / "soc_top.sv").read_text(encoding="utf-8")
    assert "simple_bus_to_wishbone_bridge" in rtl
