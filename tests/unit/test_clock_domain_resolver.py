from socfw.clock.domain_resolver import ClockDomainResolver, build_resolver


def test_primary_domain_returns_board_net():
    r = ClockDomainResolver(primary_net="SYS_CLK", generated={"sys_clk": "SYS_CLK"})
    assert r.net_for_domain("sys_clk") == "SYS_CLK"


def test_generated_domain_returns_instance_output_net():
    r = ClockDomainResolver(
        primary_net="SYS_CLK",
        generated={"sys_clk": "SYS_CLK", "clk_100mhz": "clkpll_c0"},
    )
    assert r.net_for_domain("clk_100mhz") == "clkpll_c0"


def test_unknown_domain_falls_back_to_primary():
    r = ClockDomainResolver(primary_net="SYS_CLK", generated={})
    assert r.net_for_domain("unknown_domain") == "SYS_CLK"


def test_build_resolver_from_board_and_project():
    from unittest.mock import MagicMock
    from socfw.model.project import GeneratedClockRequest

    board = MagicMock()
    board.sys_clock.top_name = "SYS_CLK"

    project = MagicMock()
    project.primary_clock_domain = "sys_clk"
    project.generated_clocks = [
        GeneratedClockRequest(
            domain="clk_100mhz",
            source_instance="clkpll",
            source_output="c0",
        )
    ]

    r = build_resolver(board, project)
    assert r.net_for_domain("sys_clk") == "SYS_CLK"
    assert r.net_for_domain("clk_100mhz") == "clkpll_c0"
    assert r.primary_net == "SYS_CLK"
