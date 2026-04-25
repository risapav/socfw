from socfw.config.normalizers.ip import normalize_ip_document


def test_ip_normalizer_converts_clock_output_interfaces():
    norm = normalize_ip_document(
        {
            "version": 2,
            "kind": "ip",
            "ip": {
                "name": "clkpll",
                "module": "clkpll",
                "category": "clock",
            },
            "artifacts": {
                "synthesis": ["clkpll.qip"],
            },
            "port_bindings": {
                "clock": "inclk0",
                "reset": "areset",
            },
            "config": {
                "active_high_reset": True,
                "needs_bus": False,
            },
            "interfaces": [
                {
                    "type": "clock_output",
                    "signals": [
                        {
                            "name": "c0",
                            "direction": "output",
                            "width": 1,
                            "top_name": "clk_100mhz",
                        }
                    ],
                }
            ],
        },
        file="clkpll.ip.yaml",
    )

    assert norm.data["clocking"]["primary_input_port"] == "inclk0"
    assert norm.data["reset"]["port"] == "areset"
    assert norm.data["reset"]["active_high"] is True
    assert norm.data["clocking"]["outputs"][0]["name"] == "c0"
    assert any(p["name"] == "c0" for p in norm.data["ports"])
    assert any("interfaces" in a for a in norm.aliases_used)


def test_ip_normalizer_no_aliases_is_clean():
    norm = normalize_ip_document(
        {
            "version": 2,
            "kind": "ip",
            "ip": {"name": "blink", "module": "blink", "category": "standalone"},
            "artifacts": {"synthesis": ["blink.sv"]},
            "clocking": {"primary_input_port": "clk", "outputs": []},
        },
        file="blink.ip.yaml",
    )

    assert norm.diagnostics == []
    assert norm.aliases_used == []
    assert norm.data["clocking"]["primary_input_port"] == "clk"


def test_ip_normalizer_injects_clk_port_when_missing():
    norm = normalize_ip_document(
        {
            "version": 2,
            "kind": "ip",
            "ip": {"name": "x", "module": "x", "category": "standalone"},
            "artifacts": {},
            "clocking": {"primary_input_port": "MY_CLK"},
        },
        file="x.ip.yaml",
    )

    assert any(p["name"] == "MY_CLK" for p in norm.data["ports"])


def test_ip_normalizer_injects_reset_port_when_missing():
    norm = normalize_ip_document(
        {
            "version": 2,
            "kind": "ip",
            "ip": {"name": "x", "module": "x", "category": "standalone"},
            "artifacts": {},
            "reset": {"port": "rst_n"},
        },
        file="x.ip.yaml",
    )

    assert any(p["name"] == "rst_n" for p in norm.data["ports"])
