from socfw.build.full_pipeline import FullBuildPipeline


def test_missing_timing_file_reports_clear_path_error(tmp_path):
    project = tmp_path / "project.yaml"
    project.write_text(
        """
version: 2
kind: project

project:
  name: bad_timing
  mode: standalone
  board: qmtech_ep4ce55

clocks:
  primary:
    domain: sys_clk
    source: board:SYS_CLK
  generated: []

timing:
  file: missing_timing.yaml

registries:
  packs: []
  ip: []
  cpu: []

modules: []
""",
        encoding="utf-8",
    )

    result = FullBuildPipeline().validate(str(project))

    assert not result.ok
    assert any(d.code == "PATH_TIMING001" for d in result.diagnostics)
