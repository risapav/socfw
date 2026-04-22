import shutil

import pytest
from pathlib import Path

from socfw.build.context import BuildRequest
from socfw.build.two_pass_flow import TwoPassBuildFlow


@pytest.mark.skipif(
    shutil.which("riscv32-unknown-elf-gcc") is None,
    reason="RISC-V toolchain not installed",
)
def test_build_picorv32_fw(tmp_path):
    templates = "socfw/templates"
    project = "tests/golden/fixtures/picorv32_soc/project.yaml"
    out_dir = tmp_path / "out"

    flow = TwoPassBuildFlow(templates_dir=templates)
    result = flow.run(BuildRequest(project_file=project, out_dir=str(out_dir)))

    assert result.ok

    assert (out_dir / "fw" / "firmware.elf").exists()
    assert (out_dir / "fw" / "firmware.bin").exists()
    assert (out_dir / "fw" / "firmware.hex").exists()
    assert (out_dir / "rtl" / "soc_top.sv").exists()
    assert (out_dir / "sw" / "soc_map.h").exists()
