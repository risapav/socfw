import shutil

import pytest

from socfw.build.context import BuildRequest
from socfw.build.two_pass_flow import TwoPassBuildFlow


@pytest.mark.skipif(
    shutil.which("riscv32-unknown-elf-gcc") is None,
    reason="RISC-V toolchain not installed",
)
def test_build_axi_bridge_soc(tmp_path):
    templates = "socfw/templates"
    project = "tests/golden/fixtures/axi_bridge_soc/project.yaml"
    out_dir = tmp_path / "out"

    flow = TwoPassBuildFlow(templates_dir=templates)
    result = flow.run(BuildRequest(project_file=project, out_dir=str(out_dir)))

    assert result.ok, [str(d) for d in result.diagnostics]

    rtl = (out_dir / "rtl" / "soc_top.sv").read_text(encoding="utf-8")
    assert "simple_bus_to_axi_lite_bridge" in rtl
    assert "axi_lite_if" in rtl
    assert "axi_gpio" in rtl
