import json

from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline


def test_build_writes_json_provenance_artifact(tmp_path):
    out_dir = tmp_path / "out"

    result = FullBuildPipeline().run(
        BuildRequest(
            project_file="tests/golden/fixtures/vendor_sdram_soc/project.yaml",
            out_dir=str(out_dir),
        )
    )

    assert result.ok, [f"{d.code}: {d.message}" for d in result.diagnostics]

    json_file = out_dir / "reports" / "build_provenance.json"
    assert json_file.exists()

    data = json.loads(json_file.read_text(encoding="utf-8"))
    assert data["project_name"] == "vendor_sdram_soc"
    assert data["board_id"] == "qmtech_ep4ce55"
    assert "sdram_ctrl" in data["ip_types"]
    assert "sdram0: simple_bus -> wishbone" in data["bridge_pairs"]
