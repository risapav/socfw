from socfw.board.profile_resolver import ProfileResolver

PROFILES = {
    "minimal": ["onboard.leds"],
    "hdmi": ["onboard.hdmi"],
    "sdram": ["external.sdram"],
    "headers": ["external.headers.P8.gpio", "external.headers.P5.gpio"],
}


def test_resolve_known_profile():
    resolver = ProfileResolver(PROFILES)
    result = resolver.resolve("minimal")
    assert result == ["board:onboard.leds"]


def test_resolve_unknown_profile_returns_none():
    resolver = ProfileResolver(PROFILES)
    assert resolver.resolve("unknown_profile") is None


def test_expand_features_profile_only():
    resolver = ProfileResolver(PROFILES)
    result = resolver.expand_features("hdmi", [])
    assert "board:onboard.hdmi" in result


def test_expand_features_profile_plus_use():
    resolver = ProfileResolver(PROFILES)
    result = resolver.expand_features("minimal", ["board:external.headers.P5.gpio"])
    assert "board:onboard.leds" in result
    assert "board:external.headers.P5.gpio" in result


def test_expand_features_no_duplicates():
    resolver = ProfileResolver(PROFILES)
    result = resolver.expand_features("minimal", ["board:onboard.leds"])
    assert result.count("board:onboard.leds") == 1


def test_expand_features_no_profile():
    resolver = ProfileResolver(PROFILES)
    result = resolver.expand_features(None, ["board:onboard.leds"])
    assert result == ["board:onboard.leds"]


def test_headers_profile():
    resolver = ProfileResolver(PROFILES)
    result = resolver.resolve("headers")
    assert "board:external.headers.P8.gpio" in result
    assert "board:external.headers.P5.gpio" in result
