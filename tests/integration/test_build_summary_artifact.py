from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline


def test_build_writes_build_summary_artifact(tmp_path):
    out_dir = tmp_path / "out"

    result = FullBuildPipeline().run(
        BuildRequest(
            project_file="tests/golden/fixtures/vendor_sdram_soc/project.yaml",
            out_dir=str(out_dir),
        )
    )

    assert result.ok, [f"{d.code}: {d.message}" for d in result.diagnostics]

    summary = out_dir / "reports" / "build_summary.md"
    assert summary.exists()

    text = summary.read_text(encoding="utf-8")
    assert "# Build Summary" in text
    assert "vendor_sdram_soc" in text
    assert "qmtech_ep4ce55" in text
    assert "sdram0: simple_bus -> wishbone" in text
    assert "sdram_ctrl.qip" in text
