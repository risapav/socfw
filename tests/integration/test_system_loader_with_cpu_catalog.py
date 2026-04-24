from pathlib import Path

from socfw.config.system_loader import SystemLoader


def test_system_loader_loads_cpu_catalog_and_resolves_project_cpu(tmp_path):
    packs_builtin = Path("packs/builtin").resolve()

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
  port: null
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

    cpu_dir = tmp_path / "cpu"
    cpu_dir.mkdir()
    cpu_rtl_dir = cpu_dir / "rtl"
    cpu_rtl_dir.mkdir()
    (cpu_rtl_dir / "dummy_cpu.sv").write_text("// dummy cpu rtl\n", encoding="utf-8")

    (cpu_dir / "dummy_cpu.cpu.yaml").write_text(
        """
version: 2
kind: cpu

cpu:
  name: dummy_cpu
  module: dummy_cpu
  family: test

clock_port: SYS_CLK
reset_port: RESET_N
irq_port: irq

bus_master:
  port_name: bus
  protocol: simple_bus
  addr_width: 32
  data_width: 32

default_params: {}

artifacts:
  - rtl/dummy_cpu.sv
""",
        encoding="utf-8",
    )

    project_file = tmp_path / "project.yaml"
    project_file.write_text(
        f"""
version: 2
kind: project

project:
  name: demo_soc
  mode: soc
  board: qmtech_ep4ce55

registries:
  packs:
    - {packs_builtin}
  ip:
    - {ip_dir}
  cpu:
    - {cpu_dir}

clocks:
  primary:
    domain: sys_clk
    source: board:sys_clk
  generated: []

cpu:
  instance: cpu0
  type: dummy_cpu
  fabric: main

modules:
  - instance: blink_test
    type: blink_test
""",
        encoding="utf-8",
    )

    loaded = SystemLoader().load(str(project_file))
    assert loaded.ok, [str(d) for d in loaded.diagnostics]
    assert loaded.value is not None
    assert loaded.value.cpu is not None
    assert loaded.value.cpu.type_name == "dummy_cpu"
    assert "dummy_cpu" in loaded.value.cpu_catalog
    assert loaded.value.cpu_desc() is not None
