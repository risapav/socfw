from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline


def test_build_vendor_sdram_soc(tmp_path):
    out_dir = tmp_path / "out"

    result = FullBuildPipeline().run(
        BuildRequest(
            project_file="tests/golden/fixtures/vendor_sdram_soc/project.yaml",
            out_dir=str(out_dir),
        )
    )

    assert result.ok, [f"{d.code}: {d.message}" for d in result.diagnostics]

    rtl = out_dir / "rtl" / "soc_top.sv"
    files_tcl = out_dir / "files.tcl"
    bridge_summary = out_dir / "reports" / "bridge_summary.txt"

    assert rtl.exists()
    assert files_tcl.exists()
    assert bridge_summary.exists()

    bridge_rtl = out_dir / "rtl" / "simple_bus_to_wishbone_bridge.sv"

    assert bridge_rtl.exists()
    assert "module simple_bus_to_wishbone_bridge" in bridge_rtl.read_text(encoding="utf-8")

    rtl_text = rtl.read_text(encoding="utf-8")
    assert "simple_bus_to_wishbone_bridge" in rtl_text
    assert "u_bridge_sdram0" in rtl_text
    assert "ZS_DQ" in rtl_text
    assert "sdram_ctrl sdram0" in rtl_text
    assert "input wire SYS_CLK" in rtl_text
    assert "wire reset_n;" in rtl_text
    assert ".reset_n(reset_n)" in rtl_text

    files_tcl_text = files_tcl.read_text(encoding="utf-8")
    bridge_summary_text = bridge_summary.read_text(encoding="utf-8")

    assert "QIP_FILE" in files_tcl_text
    assert "sdram_ctrl.qip" in files_tcl_text
    assert "SDC_FILE" in files_tcl_text
    assert "sdram_ctrl.sdc" in files_tcl_text

    assert "sdram0: simple_bus -> wishbone" in bridge_summary_text
