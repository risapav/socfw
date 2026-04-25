from socfw.config.normalizers.board_kind import infer_kind, normalize_board_resource_kinds


def test_infer_vector_from_width_and_pins():
    assert infer_kind({"top_name": "X", "direction": "output", "width": 6, "pins": ["A1"]}) == "vector"


def test_infer_scalar_from_pin():
    assert infer_kind({"top_name": "X", "direction": "output", "pin": "H1"}) == "scalar"


def test_infer_inout_from_direction():
    assert infer_kind({"top_name": "X", "direction": "inout", "width": 4, "pins": ["A1"]}) == "inout"


def test_no_inference_for_container():
    assert infer_kind({"top_name": "X", "signals": {"rx": {"pin": "J2"}}}) is None


def test_normalize_adds_kind_to_resource():
    resources = {
        "onboard": {
            "leds": {
                "top_name": "ONB_LEDS",
                "direction": "output",
                "width": 6,
                "pins": ["A1", "A2", "A3", "A4", "A5", "A6"],
            }
        }
    }
    result = normalize_board_resource_kinds(resources)
    assert result["onboard"]["leds"]["kind"] == "vector"


def test_normalize_preserves_existing_kind():
    resources = {
        "external": {
            "sdram": {
                "dq": {
                    "kind": "inout",
                    "top_name": "ZS_DQ",
                    "direction": "inout",
                    "width": 16,
                    "pins": ["T10"] * 16,
                }
            }
        }
    }
    result = normalize_board_resource_kinds(resources)
    assert result["external"]["sdram"]["dq"]["kind"] == "inout"


def test_infer_scalar_only_pin():
    assert infer_kind({"top_name": "X", "direction": "output", "pin": "V2"}) == "scalar"
