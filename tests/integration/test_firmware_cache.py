import shutil
import pytest
from pathlib import Path

from socfw.build.context import BuildRequest
from socfw.build.two_pass_flow import TwoPassBuildFlow


@pytest.mark.skipif(
    shutil.which("riscv32-unknown-elf-gcc") is None,
    reason="RISC-V toolchain not installed",
)
def test_firmware_cache_reuses_outputs(tmp_path):
    templates = "socfw/templates"
    project = "tests/golden/fixtures/picorv32_soc/project.yaml"
    out_dir = tmp_path / "out"

    flow = TwoPassBuildFlow(templates_dir=templates)

    first = flow.run(BuildRequest(project_file=project, out_dir=str(out_dir)))
    assert first.ok

    fw_hex = out_dir / "fw" / "firmware.hex"
    assert fw_hex.exists()
    mtime1 = fw_hex.stat().st_mtime

    second = flow.run(BuildRequest(project_file=project, out_dir=str(out_dir)))
    assert second.ok
    mtime2 = fw_hex.stat().st_mtime

    assert mtime2 == mtime1
