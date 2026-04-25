from socfw.board.feature_resolver import FeatureResolver, resolve_feature_ref


ALIASES = {
    "leds": "onboard.leds",
    "sdram": "external.sdram",
    "buttons": "onboard.buttons",
}


def test_resolve_onboard_path():
    resolver = FeatureResolver()
    assert resolver.resolve(["board:onboard.leds"]) == ["onboard.leds"]


def test_resolve_external_path():
    resolver = FeatureResolver()
    assert resolver.resolve(["board:external.sdram.dq"]) == ["external.sdram.dq"]


def test_resolve_alias():
    resolver = FeatureResolver(ALIASES)
    assert resolver.resolve(["board:@leds"]) == ["onboard.leds"]


def test_resolve_alias_sdram():
    resolver = FeatureResolver(ALIASES)
    assert resolver.resolve(["board:@sdram"]) == ["external.sdram"]


def test_resolve_unknown_alias_returns_empty():
    resolver = FeatureResolver(ALIASES)
    result = resolver.resolve(["board:@unknown"])
    assert result == []


def test_resolve_multiple():
    resolver = FeatureResolver(ALIASES)
    result = resolver.resolve(["board:@leds", "board:external.pmod.j10_led8"])
    assert result == ["onboard.leds", "external.pmod.j10_led8"]


def test_resolve_non_board_ref_skipped():
    resolver = FeatureResolver()
    assert resolver.resolve(["onboard.leds"]) == []


def test_resolve_one():
    resolver = FeatureResolver(ALIASES)
    assert resolver.resolve_one("board:@buttons") == "onboard.buttons"
    assert resolver.resolve_one("board:@missing") is None


def test_standalone_fn_no_alias():
    assert resolve_feature_ref("board:onboard.leds") == "onboard.leds"
    assert resolve_feature_ref("board:@leds") is None
    assert resolve_feature_ref("not:a:board:ref") is None
