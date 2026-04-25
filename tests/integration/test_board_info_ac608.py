from pathlib import Path

import pytest

from socfw.config.board_loader import BoardLoader
from socfw.diagnostics.board_info import BoardInfoReport

BOARD_FILE = str(
    Path(__file__).resolve().parents[2] / "packs" / "builtin" / "boards" / "ac608_ep4ce15" / "board.yaml"
)


@pytest.fixture(scope="module")
def board():
    result = BoardLoader().load(BOARD_FILE)
    assert result.ok, [str(d) for d in result.diagnostics]
    return result.value


def test_board_info_loads(board):
    assert board.board_id == "ac608_ep4ce15"


def test_board_info_report_header(board):
    report = BoardInfoReport().build(board)
    assert "Board: ac608_ep4ce15" in report
    assert "FPGA:" in report
    assert "Clock:" in report
    assert "50 MHz" in report


def test_board_info_report_has_resources(board):
    report = BoardInfoReport().build(board)
    assert "Resources:" in report
    assert "onboard.leds" in report


def test_board_info_report_shows_pins(board):
    report = BoardInfoReport().build(board)
    assert "pins" in report
