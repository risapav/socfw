from socfw.board.derived_resources import derive_resources


BOARD_DATA = {
    "resources": {
        "connectors": {
            "pmod": {
                "J10": {
                    "io_standard": "3.3-V LVTTL",
                    "pins": {
                        1: "H1", 2: "F1", 3: "E1", 4: "C1",
                        7: "H2", 8: "F2", 9: "D2", 10: "C2",
                    },
                }
            },
            "headers": {
                "P8": {
                    "pins": {
                        1: "R1", 2: "T2", 3: "R3", 4: "T3",
                        5: "T9", 6: "R4", 7: "T4", 8: "R5",
                        9: "T5", 10: "R6", 11: "T6", 12: "R7",
                        13: "T7", 14: "R10",
                    },
                }
            },
        }
    },
    "derived_resources": [
        {
            "name": "external.pmod.j10_gpio8",
            "from": "connectors.pmod.J10",
            "role": "gpio8",
            "top_name": "PMOD_J10_D",
        },
        {
            "name": "external.pmod.j10_led8",
            "from": "connectors.pmod.J10",
            "role": "led8",
            "top_name": "PMOD_J10_LED",
        },
        {
            "name": "external.headers.P8.gpio",
            "from": "connectors.headers.P8",
            "role": "gpio14",
            "top_name": "HDR_P8_D",
        },
    ],
}


def test_derive_gpio8():
    result = derive_resources(BOARD_DATA)
    res = result["resources"]["external"]["pmod"]["j10_gpio8"]
    assert res["kind"] == "inout"
    assert res["direction"] == "inout"
    assert res["width"] == 8
    assert res["top_name"] == "PMOD_J10_D"
    assert res["io_standard"] == "3.3-V LVTTL"
    assert res["pins"] == ["H1", "F1", "E1", "C1", "H2", "F2", "D2", "C2"]


def test_derive_led8():
    result = derive_resources(BOARD_DATA)
    res = result["resources"]["external"]["pmod"]["j10_led8"]
    assert res["kind"] == "vector"
    assert res["direction"] == "output"
    assert res["pins"] == ["H1", "F1", "E1", "C1", "H2", "F2", "D2", "C2"]


def test_derive_header_gpio14():
    result = derive_resources(BOARD_DATA)
    res = result["resources"]["external"]["headers"]["P8"]["gpio"]
    assert res["kind"] == "inout"
    assert res["width"] == 14
    assert len(res["pins"]) == 14
    assert res["pins"][0] == "R1"


def test_original_not_mutated():
    original_pins = BOARD_DATA["resources"]["connectors"]["pmod"]["J10"]["pins"].copy()
    derive_resources(BOARD_DATA)
    assert BOARD_DATA["resources"]["connectors"]["pmod"]["J10"]["pins"] == original_pins


def test_missing_role_skipped():
    data = {
        "resources": {"connectors": {"pmod": {"J10": {"pins": {1: "H1"}}}}},
        "derived_resources": [
            {"name": "external.pmod.j10_foo", "from": "connectors.pmod.J10", "role": "unknown_role", "top_name": "FOO"}
        ],
    }
    result = derive_resources(data)
    assert "external" not in result["resources"]
