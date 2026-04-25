from pathlib import Path

from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline

FIXTURE = Path("tests/golden/fixtures/vendor_pll_soc/project.yaml")


def test_vendor_pll_pack_build(tmp_path):
    out_dir = tmp_path / "out"
    result = FullBuildPipeline(templates_dir="socfw/templates").run(
        BuildRequest(project_file=str(FIXTURE), out_dir=str(out_dir))
    )
    assert result.ok, [str(d) for d in result.diagnostics]

    rtl = (out_dir / "rtl" / "soc_top.sv").read_text(encoding="utf-8")
    files_tcl = (out_dir / "hal" / "files.tcl").read_text(encoding="utf-8")

    assert "sys_pll" in rtl
    assert "QIP_FILE" in files_tcl
    assert "sys_pll.qip" in files_tcl
    assert "SDC_FILE" in files_tcl
    assert "sys_pll.sdc" in files_tcl
