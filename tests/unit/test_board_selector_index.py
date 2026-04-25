from socfw.board.selector_index import build_selector_index
from socfw.config.board_loader import BoardLoader


BOARD_FILE = "packs/builtin/boards/ac608_ep4ce15/board.yaml"


def _load_board():
    return BoardLoader().load(BOARD_FILE).value


def test_resources_includes_onboard():
    index = build_selector_index(_load_board())
    assert "board:onboard.leds" in index.resources
    assert "board:onboard.buttons" in index.resources


def test_resources_includes_external():
    index = build_selector_index(_load_board())
    assert any(r.startswith("board:external.") for r in index.resources)


def test_resources_excludes_connectors():
    index = build_selector_index(_load_board())
    assert not any("connectors" in r for r in index.resources)


def test_connectors_listed_separately():
    index = build_selector_index(_load_board())
    assert any("connectors" in c for c in index.connectors)
    assert "board:connectors.headers.P8" in index.connectors


def test_aliases_present():
    index = build_selector_index(_load_board())
    assert "board:@leds" in index.aliases
    assert "board:@sdram" in index.aliases


def test_profiles_present():
    index = build_selector_index(_load_board())
    assert "minimal" in index.profiles
    assert "sdram" in index.profiles
    assert "hdmi" in index.profiles


def test_board_id():
    index = build_selector_index(_load_board())
    assert index.board_id == "ac608_ep4ce15"
