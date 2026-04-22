from socfw.config.board_loader import BoardLoader


def test_load_board_minimal(tmp_path):
    fp = tmp_path / "board.yaml"
    fp.write_text(
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
  connectors: {}
""",
        encoding="utf-8",
    )

    res = BoardLoader().load(str(fp))
    assert res.ok
    assert res.value is not None
    assert res.value.board_id == "test_board"
    assert res.value.sys_clock.top_name == "SYS_CLK"
