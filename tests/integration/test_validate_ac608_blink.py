from socfw.config.board_loader import BoardLoader
from socfw.core.diagnostics import Severity

BOARD_FILE = "packs/builtin/boards/ac608_ep4ce15/board.yaml"


def test_ac608_board_loads_and_leds_resolve():
    result = BoardLoader().load(BOARD_FILE)
    errors = [d for d in result.diagnostics if d.severity == Severity.ERROR]
    assert not errors, [d.message for d in errors]

    board = result.value
    leds = board.resolve_ref("board:onboard.leds")
    sig = leds.default_signal()
    assert sig is not None
    assert sig.width == 5


def test_ac608_buttons_resolve():
    board = BoardLoader().load(BOARD_FILE).value
    buttons = board.resolve_ref("board:onboard.buttons")
    sig = buttons.default_signal()
    assert sig is not None
    assert sig.width == 3


def test_ac608_uart_rx_resolves():
    board = BoardLoader().load(BOARD_FILE).value
    ref = board.resolve_ref("board:onboard.uart.rx")
    from socfw.model.board import BoardScalarSignal
    assert isinstance(ref, BoardScalarSignal)
    assert ref.top_name == "UART_RX"


def test_ac608_sdram_external_resources_resolve():
    board = BoardLoader().load(BOARD_FILE).value
    for name in ("clk", "cke", "cs_n", "ras_n", "cas_n", "we_n", "dq", "addr", "ba", "dqm"):
        ref = board.resolve_ref(f"board:external.sdram.{name}")
        assert ref is not None, f"external.sdram.{name} not resolved"
