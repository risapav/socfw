import shutil
import pytest
from pathlib import Path

from socfw.build.context import BuildRequest
from socfw.build.two_pass_flow import TwoPassBuildFlow
from socfw.tools.sim_runner import SimRunner


@pytest.mark.skipif(
    shutil.which("iverilog") is None,
    reason="iverilog not installed",
)
def test_sim_picorv32_smoke(tmp_path):
    templates = "socfw/templates"
    project = "tests/golden/fixtures/picorv32_soc/project.yaml"
    out_dir = tmp_path / "out"

    flow = TwoPassBuildFlow(templates_dir=templates)
    result = flow.run(BuildRequest(project_file=project, out_dir=str(out_dir)))

    assert result.ok

    sim = SimRunner().run_iverilog(str(out_dir))
    assert sim.ok
    assert (out_dir / "sim" / "files.f").exists()
