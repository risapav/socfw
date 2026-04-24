from socfw.config.cpu_loader import CpuLoader


def test_cpu_loader_loads_descriptor_and_normalizes_artifacts(tmp_path):
    cpu_dir = tmp_path / "cpu"
    cpu_dir.mkdir()

    rtl_dir = cpu_dir / "rtl"
    rtl_dir.mkdir()
    (rtl_dir / "dummy_cpu.sv").write_text("// dummy cpu\n", encoding="utf-8")

    cpu_file = cpu_dir / "dummy_cpu.cpu.yaml"
    cpu_file.write_text(
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

    res = CpuLoader().load_file(str(cpu_file))
    assert res.ok
    assert res.value is not None
    assert res.value.name == "dummy_cpu"
    assert res.value.module == "dummy_cpu"
    assert res.value.bus_master is not None
    assert res.value.bus_master.protocol == "simple_bus"
    assert len(res.value.artifacts) == 1
    assert res.value.artifacts[0].endswith("rtl/dummy_cpu.sv")
