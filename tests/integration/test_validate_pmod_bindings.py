from socfw.config.board_loader import BoardLoader
from socfw.core.diagnostics import Severity

BOARD_FILE = "packs/builtin/boards/qmtech_ep4ce55/board.yaml"


def test_board_loads_without_errors():
    result = BoardLoader().load(BOARD_FILE)
    errors = [d for d in result.diagnostics if d.severity == Severity.ERROR]
    assert not errors, [d.message for d in errors]
    assert result.value is not None


def test_pmod_j10_led6_resolves():
    board = BoardLoader().load(BOARD_FILE).value
    ref = board.resolve_ref("board:external.pmod.j10_led6")
    assert ref["width"] == 6
    assert ref["direction"] == "output"
    assert len(ref["pins"]) == 6


def test_pmod_j10_led8_resolves():
    board = BoardLoader().load(BOARD_FILE).value
    ref = board.resolve_ref("board:external.pmod.j10_led8")
    assert ref["width"] == 8
    assert len(ref["pins"]) == 8


def test_pmod_j11_led6_resolves():
    board = BoardLoader().load(BOARD_FILE).value
    ref = board.resolve_ref("board:external.pmod.j11_led6")
    assert ref["width"] == 6
    assert ref["top_name"] == "PMOD_J11_LED"


def test_pmod_j10_buttons8_resolves():
    board = BoardLoader().load(BOARD_FILE).value
    ref = board.resolve_ref("board:external.pmod.j10_buttons8")
    assert ref["width"] == 8
    assert ref["direction"] == "input"


def test_pmod_j11_buttons8_resolves():
    board = BoardLoader().load(BOARD_FILE).value
    ref = board.resolve_ref("board:external.pmod.j11_buttons8")
    assert ref["width"] == 8
    assert ref["direction"] == "input"
    assert "R1" in ref["pins"]
    assert "M2" in ref["pins"]
