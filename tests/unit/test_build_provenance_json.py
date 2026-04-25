import json

from socfw.build.provenance import SocBuildProvenance
from socfw.reports.build_provenance_json import BuildProvenanceJsonReport


def test_build_provenance_json_report_is_stable_json():
    provenance = SocBuildProvenance(
        project_name="demo",
        project_mode="soc",
        board_id="qmtech_ep4ce55",
        ip_types=["sdram_ctrl"],
        module_instances=["sdram0"],
        bridge_pairs=["sdram0: simple_bus -> wishbone"],
        generated_files=["rtl/soc_top.sv"],
    )

    text = BuildProvenanceJsonReport().build(provenance)
    data = json.loads(text)

    assert data["project_name"] == "demo"
    assert data["board_id"] == "qmtech_ep4ce55"
    assert data["bridge_pairs"] == ["sdram0: simple_bus -> wishbone"]
