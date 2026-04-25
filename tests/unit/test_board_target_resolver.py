from pathlib import Path
import pytest
from socfw.config.board_loader import BoardLoader
from socfw.board.target_resolver import BoardTargetResolver

BOARD_FILE = str(
    Path(__file__).resolve().parents[2] / "packs" / "builtin" / "boards" / "ac608_ep4ce15" / "board.yaml"
)


@pytest.fixture(scope="module")
def resolver():
    board = BoardLoader().load(BOARD_FILE).value
    return BoardTargetResolver(board)


def test_resolve_plain_path(resolver):
    ref, ok = resolver.resolve("board:external.sdram.dq")
    assert ref == "board:external.sdram.dq"


def test_resolve_alias_leds(resolver):
    ref, ok = resolver.resolve("board:@leds")
    assert ref == "board:onboard.leds"


def test_resolve_alias_sdram(resolver):
    ref, ok = resolver.resolve("board:@sdram")
    assert ref == "board:external.sdram"


def test_resolve_profile_minimal(resolver):
    refs = resolver.resolve_feature_profile("minimal")
    assert refs is not None
    assert "board:onboard.leds" in refs


def test_resolve_profile_unknown(resolver):
    assert resolver.resolve_feature_profile("nonexistent") is None


def test_expand_features_profile_plus_use(resolver):
    refs = resolver.expand_features("minimal", ["board:@p8"])
    assert "board:onboard.leds" in refs
    assert "board:external.headers.P8.gpio" in refs


def test_list_resource_paths(resolver):
    paths = resolver.list_resource_paths()
    assert any("sdram" in p for p in paths)
    assert any("leds" in p for p in paths)
