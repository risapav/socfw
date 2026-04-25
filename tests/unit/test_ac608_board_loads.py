from socfw.config.board_loader import BoardLoader
from socfw.core.diagnostics import Severity

BOARD_FILE = "packs/builtin/boards/ac608_ep4ce15/board.yaml"


def test_ac608_board_loads_without_errors():
    result = BoardLoader().load(BOARD_FILE)
    errors = [d for d in result.diagnostics if d.severity == Severity.ERROR]
    assert not errors, [d.message for d in errors]
    assert result.value is not None


def test_ac608_board_id():
    board = BoardLoader().load(BOARD_FILE).value
    assert board.board_id == "ac608_ep4ce15"
    assert board.fpga_part == "EP4CE15E22C8"


def test_ac608_leds_resolve():
    board = BoardLoader().load(BOARD_FILE).value
    ref = board.resolve_ref("board:onboard.leds")
    sig = ref.default_signal()
    assert sig is not None
    assert sig.width == 5


def test_ac608_sdram_dq_resolves():
    board = BoardLoader().load(BOARD_FILE).value
    ref = board.resolve_ref("board:external.sdram.dq")
    assert ref["kind"] == "inout"
    assert ref["width"] == 16
    assert len(ref["pins"]) == 16


def test_ac608_hdmi_tmds_p_resolves():
    from socfw.model.board import BoardVectorSignal
    board = BoardLoader().load(BOARD_FILE).value
    ref = board.resolve_ref("board:onboard.hdmi.tmds_p")
    assert isinstance(ref, BoardVectorSignal)
    assert ref.width == 4
    assert ref.top_name == "TMDS_P"
