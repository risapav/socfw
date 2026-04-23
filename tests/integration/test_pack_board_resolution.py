from pathlib import Path

from socfw.config.system_loader import SystemLoader


def test_board_resolves_from_pack(tmp_path):
    pack = tmp_path / "packs" / "builtin" / "boards" / "demo_board"
    pack.mkdir(parents=True)

    (tmp_path / "packs" / "builtin" / "pack.yaml").write_text(
        "version: 1\nkind: pack\nname: builtin\nprovides: [boards]\n",
        encoding="utf-8",
    )

    (pack / "board.yaml").write_text(
        "version: 2\nkind: board\n"
        "board:\n  id: demo_board\n"
        "fpga:\n  family: testfam\n  part: testpart\n"
        "system:\n"
        "  clock:\n    id: clk\n    top_name: SYS_CLK\n    pin: A1\n    frequency_hz: 50000000\n"
        "  reset:\n    id: rst\n    top_name: RESET_N\n    pin: A2\n    active_low: true\n"
        "resources:\n  onboard: {}\n  connectors: {}\n",
        encoding="utf-8",
    )

    project = tmp_path / "project.yaml"
    project.write_text(
        "version: 2\nkind: project\n"
        "project:\n  name: demo\n  mode: standalone\n  board: demo_board\n"
        "registries:\n  packs:\n    - ./packs/builtin\n"
        "clocks:\n  primary:\n    domain: sys_clk\n    source: board:sys_clk\n  generated: []\n"
        "modules: []\n",
        encoding="utf-8",
    )

    loaded = SystemLoader().load(str(project))
    assert loaded.ok
    assert loaded.value is not None
    assert loaded.value.board.board_id == "demo_board"
