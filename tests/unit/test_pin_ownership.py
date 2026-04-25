from socfw.board.feature_expansion import expand_features
from socfw.board.pin_ownership import PinUse, collect_pin_ownership
from socfw.config.board_loader import BoardLoader


BOARD_FILE = "packs/builtin/boards/ac608_ep4ce15/board.yaml"


def _board():
    return BoardLoader().load(BOARD_FILE).value


def test_onboard_leds_ownership():
    board = _board()
    selected = expand_features(board, profile="minimal", use=[])
    pins = collect_pin_ownership(board, selected)
    resources = {p.resource_path for p in pins}
    assert "onboard.leds" in resources


def test_onboard_leds_pin_count():
    board = _board()
    selected = expand_features(board, profile="minimal", use=[])
    pins = [p for p in collect_pin_ownership(board, selected) if p.resource_path == "onboard.leds"]
    assert len(pins) == 5


def test_onboard_leds_bit_indices():
    board = _board()
    selected = expand_features(board, profile="minimal", use=[])
    pins = [p for p in collect_pin_ownership(board, selected) if p.resource_path == "onboard.leds"]
    bits = {p.bit for p in pins}
    assert bits == {0, 1, 2, 3, 4}


def test_sdram_external_pins():
    board = _board()
    selected = expand_features(board, profile="sdram", use=[])
    pins = collect_pin_ownership(board, selected)
    resources = {p.resource_path for p in pins}
    assert any("external.sdram" in r for r in resources)


def test_pin_use_has_top_name():
    board = _board()
    selected = expand_features(board, profile="minimal", use=[])
    pins = collect_pin_ownership(board, selected)
    for p in pins:
        assert p.top_name, f"Missing top_name for {p.resource_path}"


def test_no_pins_for_empty_selection():
    board = _board()
    selected = expand_features(board, profile=None, use=[])
    pins = collect_pin_ownership(board, selected)
    assert pins == []
