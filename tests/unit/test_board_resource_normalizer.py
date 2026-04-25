from socfw.config.normalizers.board import normalize_board_document


def test_dict_pins_normalized_to_sorted_list():
    data = {
        "resources": {
            "onboard": {
                "leds": {
                    "kind": "vector",
                    "top_name": "ONB_LEDS",
                    "direction": "output",
                    "width": 6,
                    "pins": {0: "A1", 1: "A2", 2: "A3", 3: "A4", 4: "A5", 5: "A6"},
                }
            }
        }
    }
    norm = normalize_board_document(data, file="board.yaml")
    leds = norm.data["resources"]["onboard"]["leds"]
    assert leds["pins"] == ["A1", "A2", "A3", "A4", "A5", "A6"]
    assert len(norm.diagnostics) == 1
    assert norm.diagnostics[0].code == "BRD_ALIAS001"


def test_list_pins_unchanged():
    data = {
        "resources": {
            "onboard": {
                "leds": {
                    "kind": "vector",
                    "top_name": "ONB_LEDS",
                    "direction": "output",
                    "width": 6,
                    "pins": ["A1", "A2", "A3", "A4", "A5", "A6"],
                }
            }
        }
    }
    norm = normalize_board_document(data, file="board.yaml")
    leds = norm.data["resources"]["onboard"]["leds"]
    assert leds["pins"] == ["A1", "A2", "A3", "A4", "A5", "A6"]
    assert norm.diagnostics == []


def test_no_resources_is_clean():
    norm = normalize_board_document({"board": {"id": "test"}}, file="board.yaml")
    assert norm.diagnostics == []
    assert norm.aliases_used == []


def test_bundle_signals_pins_normalized():
    data = {
        "resources": {
            "external": {
                "pmod": {
                    "j10_hdmi": {
                        "kind": "bundle",
                        "signals": {
                            "d": {
                                "kind": "vector",
                                "top_name": "HDMI_D",
                                "direction": "output",
                                "width": 4,
                                "pins": {0: "H2", 1: "F2", 2: "D2", 3: "C2"},
                            }
                        },
                    }
                }
            }
        }
    }
    norm = normalize_board_document(data, file="board.yaml")
    sig = norm.data["resources"]["external"]["pmod"]["j10_hdmi"]["signals"]["d"]
    assert sig["pins"] == ["H2", "F2", "D2", "C2"]
    assert len(norm.diagnostics) == 1


def test_legacy_soc_top_name_renamed():
    data = {
        "resources": {
            "onboard": {
                "leds": {
                    "kind": "vector",
                    "soc_top_name": "ONB_LEDS",
                    "dir": "output",
                    "standard": "3.3-V LVTTL",
                    "width": 2,
                    "pins": ["A1", "A2"],
                }
            }
        }
    }
    norm = normalize_board_document(data, file="board.yaml")
    leds = norm.data["resources"]["onboard"]["leds"]
    assert leds["top_name"] == "ONB_LEDS"
    assert leds["direction"] == "output"
    assert leds["io_standard"] == "3.3-V LVTTL"
    codes = {d.code for d in norm.diagnostics}
    assert "BRD_ALIAS002" in codes
    assert "BRD_ALIAS003" in codes
    assert "BRD_ALIAS004" in codes


def test_string_indexed_dict_pins():
    data = {
        "resources": {
            "onboard": {
                "leds": {
                    "kind": "vector",
                    "top_name": "ONB_LEDS",
                    "direction": "output",
                    "width": 3,
                    "pins": {"2": "C1", "0": "A1", "1": "B1"},
                }
            }
        }
    }
    norm = normalize_board_document(data, file="board.yaml")
    assert norm.data["resources"]["onboard"]["leds"]["pins"] == ["A1", "B1", "C1"]
