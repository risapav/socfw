from socfw.board.alias_resolver import AliasResolver
from socfw.core.diagnostics import Severity

ALIASES = {
    "leds": "onboard.leds",
    "sdram": "external.sdram",
    "hdmi": "onboard.hdmi",
}


def test_passthrough_non_alias():
    resolver = AliasResolver(ALIASES)
    ref, diags = resolver.resolve_ref("board:onboard.leds")
    assert ref == "board:onboard.leds"
    assert not diags


def test_resolve_alias():
    resolver = AliasResolver(ALIASES)
    ref, diags = resolver.resolve_ref("board:@leds")
    assert ref == "board:onboard.leds"
    assert not diags


def test_resolve_alias_sdram():
    resolver = AliasResolver(ALIASES)
    ref, diags = resolver.resolve_ref("board:@sdram")
    assert ref == "board:external.sdram"
    assert not diags


def test_unknown_alias_emits_error():
    resolver = AliasResolver(ALIASES)
    ref, diags = resolver.resolve_ref("board:@unknown")
    assert ref == "board:@unknown"
    errors = [d for d in diags if d.severity == Severity.ERROR]
    assert errors
    assert "BRD_ALIAS404" in errors[0].code


def test_resolve_refs_batch():
    resolver = AliasResolver(ALIASES)
    refs, diags = resolver.resolve_refs(["board:@leds", "board:@sdram", "board:external.headers.P8.gpio"])
    assert refs == ["board:onboard.leds", "board:external.sdram", "board:external.headers.P8.gpio"]
    assert not diags


def test_non_board_ref_passthrough():
    resolver = AliasResolver(ALIASES)
    ref, diags = resolver.resolve_ref("some_other_ref")
    assert ref == "some_other_ref"
    assert not diags
