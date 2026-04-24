from socfw.build.provenance import SocBuildProvenance
from socfw.reports.build_summary import BuildSummaryReport


def test_build_summary_report_contains_key_sections():
    provenance = SocBuildProvenance(
        project_name="demo",
        project_mode="soc",
        board_id="qmtech_ep4ce55",
        cpu_type="dummy_cpu",
        cpu_module="dummy_cpu",
        ip_types=["blink_test", "sdram_ctrl"],
        module_instances=["blink0", "sdram0"],
        timing_generated_clocks=1,
        timing_false_paths=2,
        vendor_qip_files=["/tmp/sdram_ctrl.qip"],
        vendor_sdc_files=["/tmp/sdram_ctrl.sdc"],
        bridge_pairs=["sdram0: simple_bus -> wishbone"],
        generated_files=["/tmp/out/rtl/soc_top.sv"],
    )

    text = BuildSummaryReport().build(provenance)

    assert "# Build Summary" in text
    assert "qmtech_ep4ce55" in text
    assert "dummy_cpu" in text
    assert "sdram0: simple_bus -> wishbone" in text
    assert "sdram_ctrl.qip" in text


def test_build_summary_report_no_cpu():
    provenance = SocBuildProvenance(
        project_name="minimal",
        project_mode="soc",
        board_id="test_board",
    )
    text = BuildSummaryReport().build(provenance)
    assert "CPU: none" in text
    assert "none" in text


def test_build_summary_report_write(tmp_path):
    provenance = SocBuildProvenance(
        project_name="test",
        project_mode="soc",
        board_id="board_x",
    )
    path = BuildSummaryReport().write(str(tmp_path), provenance)
    assert (tmp_path / "reports" / "build_summary.md").exists()
    assert "# Build Summary" in (tmp_path / "reports" / "build_summary.md").read_text(encoding="utf-8")
