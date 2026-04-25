from socfw.board.feature_expansion import expand_features
from socfw.config.board_loader import BoardLoader


BOARD_FILE = "packs/builtin/boards/ac608_ep4ce15/board.yaml"


def _board():
    return BoardLoader().load(BOARD_FILE).value


def test_expand_profile_minimal():
    result = expand_features(_board(), profile="minimal", use=[])
    assert "onboard.leds" in result.paths


def test_expand_profile_sdram_contains_leaves():
    result = expand_features(_board(), profile="sdram", use=[])
    assert "external.sdram.addr" in result.paths
    assert "external.sdram.dq" in result.paths
    assert "external.sdram.ba" in result.paths


def test_expand_alias_use():
    result = expand_features(_board(), profile=None, use=["board:@leds"])
    assert "onboard.leds" in result.paths


def test_expand_combined_profile_and_use():
    result = expand_features(_board(), profile="sdram", use=["board:@leds"])
    assert "onboard.leds" in result.paths
    assert "external.sdram.addr" in result.paths


def test_no_duplicates():
    result = expand_features(_board(), profile="minimal", use=["board:onboard.leds"])
    assert result.paths.count("onboard.leds") == 1


def test_empty_features():
    result = expand_features(_board(), profile=None, use=[])
    assert len(result) == 0


def test_contains_operator():
    result = expand_features(_board(), profile="minimal", use=[])
    assert "onboard.leds" in result
    assert "external.sdram.dq" not in result
