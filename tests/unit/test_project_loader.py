from socfw.config.project_loader import ProjectLoader


def test_load_project_minimal(tmp_path):
    board_fp = tmp_path / "board.yaml"
    board_fp.write_text(
        """
version: 2
kind: board
board:
  id: test_board
  vendor: Test
  title: Test Board
fpga:
  family: Cyclone IV E
  part: EP4CE55F23C8
system:
  clock:
    id: sys_clk
    top_name: SYS_CLK
    pin: T2
    frequency_hz: 50000000
  reset:
    id: sys_reset_n
    top_name: RESET_N
    pin: W13
    active_low: true
resources:
  onboard: {}
""",
        encoding="utf-8",
    )

    project_fp = tmp_path / "project.yaml"
    project_fp.write_text(
        """
version: 2
kind: project
project:
  name: test_soc
  mode: soc
  board: test_board
  board_file: board.yaml
  output_dir: build/gen
registries:
  ip:
    - ip
clocks:
  primary:
    domain: sys_clk
    source: board:sys_clk
  generated: []
buses:
  - name: main
    protocol: simple_bus
    addr_width: 32
    data_width: 32
modules: []
artifacts:
  emit: [rtl]
""",
        encoding="utf-8",
    )

    res = ProjectLoader().load(str(project_fp))
    assert res.ok, [str(d) for d in res.diagnostics]
    data = res.value
    assert data is not None
    project = data["project"]
    assert project.name == "test_soc"
    assert len(project.bus_fabrics) == 1
    assert project.bus_fabrics[0].protocol == "simple_bus"


def test_load_project_with_generated_clock(tmp_path):
    board_fp = tmp_path / "board.yaml"
    board_fp.write_text(
        """
version: 2
kind: board
board:
  id: test_board
  vendor: Test
  title: Test Board
fpga:
  family: Cyclone IV E
  part: EP4CE55F23C8
system:
  clock:
    id: sys_clk
    top_name: SYS_CLK
    pin: T2
    frequency_hz: 50000000
  reset:
    id: sys_reset_n
    top_name: RESET_N
    pin: W13
    active_low: true
resources:
  onboard: {}
""",
        encoding="utf-8",
    )

    project_fp = tmp_path / "project.yaml"
    project_fp.write_text(
        """
version: 2
kind: project
project:
  name: test_pll
  mode: soc
  board: test_board
  board_file: board.yaml
  output_dir: build/gen
registries:
  ip: []
clocks:
  primary:
    domain: sys_clk
    source: board:sys_clk
  generated:
    - domain: fast_clk
      source:
        instance: clkpll
        output: c0
modules: []
artifacts:
  emit: [rtl]
""",
        encoding="utf-8",
    )

    res = ProjectLoader().load(str(project_fp))
    assert res.ok, [str(d) for d in res.diagnostics]
    data = res.value
    project = data["project"]
    gen_clocks = project.generated_clocks
    assert len(gen_clocks) == 1
    assert gen_clocks[0].domain == "fast_clk"
