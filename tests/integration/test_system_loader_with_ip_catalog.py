from pathlib import Path

from socfw.config.system_loader import SystemLoader


def test_system_loader_loads_project_board_and_ip_catalog(tmp_path):
    ip_dir = tmp_path / "ip"
    ip_dir.mkdir()

    rtl_dir = ip_dir / "rtl"
    rtl_dir.mkdir()
    (rtl_dir / "blink_test.sv").write_text("// blink test rtl\n", encoding="utf-8")

    (ip_dir / "blink_test.ip.yaml").write_text(
        """
version: 2
kind: ip

ip:
  name: blink_test
  module: blink_test
  category: standalone

origin:
  kind: source
  packaging: plain_rtl

integration:
  needs_bus: false
  generate_registers: false
  instantiate_directly: true
  dependency_only: false

reset:
  port: RESET_N
  active_high: false

clocking:
  primary_input_port: SYS_CLK
  additional_input_ports: []
  outputs: []

artifacts:
  synthesis:
    - rtl/blink_test.sv
  simulation: []
  metadata: []
""",
        encoding="utf-8",
    )

    project_file = tmp_path / "project.yaml"
    project_file.write_text(
        f"""
version: 2
kind: project

project:
  name: demo
  mode: standalone
  board: qmtech_ep4ce55
  output_dir: build/gen

registries:
  ip:
    - {ip_dir}

features:
  use: []

clocks:
  primary:
    domain: sys_clk
    source: board:SYS_CLK

modules:
  - instance: blink_test
    type: blink_test
    clocks:
      clk: sys_clk

artifacts:
  emit: [rtl]
""",
        encoding="utf-8",
    )

    loaded = SystemLoader().load(str(project_file))
    assert loaded.ok, [str(d) for d in loaded.diagnostics]
    assert loaded.value is not None
    assert loaded.value.board.board_id == "qmtech_ep4ce55"
    assert "blink_test" in loaded.value.ip_catalog
