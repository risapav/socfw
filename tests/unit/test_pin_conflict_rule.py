from socfw.config.board_loader import BoardLoader
from socfw.model.system import SystemModel
from socfw.model.project import ProjectModel
from socfw.validate.rules.pin_rules import BoardPinConflictRule, _extract_pins


BOARD_FILE = "packs/builtin/boards/qmtech_ep4ce55/board.yaml"


def _make_system(feature_refs):
    board = BoardLoader().load(BOARD_FILE).value
    return SystemModel(
        board=board,
        project=ProjectModel(
            name="test",
            mode="standalone",
            board_ref="qmtech_ep4ce55",
            modules=[],
            feature_refs=feature_refs,
        ),
        timing=None,
        ip_catalog={},
    )


def test_no_feature_refs_no_conflict():
    system = _make_system([])
    diags = BoardPinConflictRule().validate(system)
    assert not diags


def test_j11_and_sdram_conflict():
    system = _make_system([
        "board:external.pmod.j11_led8",
        "board:external.sdram.dq",
    ])
    diags = BoardPinConflictRule().validate(system)
    pin001 = [d for d in diags if d.code == "PIN001"]
    assert pin001, "Expected PIN001 for J11 vs SDRAM conflict"
    conflicting_pins = {d.message.split()[1] for d in pin001}
    # R1 and R2 are shared between J11 PMOD and SDRAM DQ
    assert "R1" in conflicting_pins or "R2" in conflicting_pins


def test_non_overlapping_resources_no_conflict():
    system = _make_system([
        "board:external.pmod.j10_led6",
        "board:external.pmod.j11_led6",
    ])
    diags = BoardPinConflictRule().validate(system)
    assert not any(d.code == "PIN001" for d in diags)


def test_extract_pins_from_scalar_dict():
    resource = {"kind": "scalar", "top_name": "X", "direction": "output", "pin": "H1"}
    assert _extract_pins(resource) == {"H1"}


def test_extract_pins_from_vector_dict():
    resource = {"kind": "vector", "top_name": "X", "direction": "output", "width": 3, "pins": ["A1", "B1", "C1"]}
    assert _extract_pins(resource) == {"A1", "B1", "C1"}


def test_extract_pins_from_bundle_dict():
    resource = {
        "kind": "bundle",
        "signals": {
            "clk": {"kind": "scalar", "top_name": "CLK", "direction": "output", "pin": "H1"},
            "d": {"kind": "vector", "top_name": "D", "direction": "output", "width": 2, "pins": ["H2", "F2"]},
        },
    }
    assert _extract_pins(resource) == {"H1", "H2", "F2"}
