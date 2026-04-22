import shutil
import pytest

from socfw.build.context import BuildRequest
from socfw.build.two_pass_flow import TwoPassBuildFlow
from socfw.tools.sim_runner import SimRunner


@pytest.mark.skipif(
    shutil.which("iverilog") is None or shutil.which("riscv32-unknown-elf-gcc") is None,
    reason="missing simulation or riscv toolchain",
)
def test_sim_picorv32_waitstate(tmp_path):
    templates = "socfw/templates"
    project = "tests/golden/fixtures/picorv32_soc/project.yaml"
    out_dir = tmp_path / "out"

    flow = TwoPassBuildFlow(templates_dir=templates)
    result = flow.run(BuildRequest(project_file=project, out_dir=str(out_dir)))

    assert result.ok
    assert (out_dir / "fw" / "firmware.hex").exists()

    sim = SimRunner().run_iverilog(str(out_dir))
    assert sim.ok
