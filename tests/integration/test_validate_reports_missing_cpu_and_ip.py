from pathlib import Path

from socfw.build.full_pipeline import FullBuildPipeline


def test_validate_reports_missing_cpu_and_ip(tmp_path):
    packs_builtin = Path("packs/builtin").resolve()

    project_file = tmp_path / "project.yaml"
    project_file.write_text(
        f"""
version: 2
kind: project

project:
  name: bad_soc
  mode: soc
  board: qmtech_ep4ce55

registries:
  packs:
    - {packs_builtin}

clocks:
  primary:
    domain: sys_clk
    source: board:sys_clk

cpu:
  instance: cpu0
  type: nonexistent_cpu
  fabric: main

modules:
  - instance: periph0
    type: nonexistent_ip
""",
        encoding="utf-8",
    )

    result = FullBuildPipeline().validate(str(project_file))
    assert not result.ok
    codes = {d.code for d in result.diagnostics}
    assert "CPU001" in codes
    assert "IP001" in codes
