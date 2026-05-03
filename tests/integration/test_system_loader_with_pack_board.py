from socfw.config.system_loader import SystemLoader


def test_system_loader_resolves_builtin_board(tmp_path):
    project_file = tmp_path / "project.yaml"
    project_file.write_text(
        """
version: 2
kind: project

project:
  name: demo
  mode: standalone
  board: qmtech_ep4ce55
  output_dir: build

registries:
  ip: []

features:
  use: []

clocks:
  primary:
    domain: sys_clk
    source: board:SYS_CLK

modules: []

artifacts:
  emit: [rtl]
""",
        encoding="utf-8",
    )

    loaded = SystemLoader().load(str(project_file))
    assert loaded.ok, [str(d) for d in loaded.diagnostics]
    assert loaded.value is not None
    assert loaded.value.project.name == "demo"
    assert loaded.value.board.board_id == "qmtech_ep4ce55"
    assert loaded.value.sources.board_file is not None
