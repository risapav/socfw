from pathlib import Path

import pytest

from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline

FIXTURE = Path("tests/golden/fixtures/ac608_blink/project.yaml")
EXPECTED = Path("tests/golden/expected/ac608_blink")


def _read(p: Path) -> str:
    return p.read_text(encoding="utf-8")


@pytest.mark.golden
def test_ac608_blink_golden(tmp_path):
    out_dir = tmp_path / "gen"

    result = FullBuildPipeline(templates_dir="socfw/templates").run(
        BuildRequest(project_file=str(FIXTURE), out_dir=str(out_dir))
    )

    assert result.ok, [f"{d.code}: {d.message}" for d in result.diagnostics]

    for rel in ["rtl/soc_top.sv", "hal/board.tcl", "reports/board_pinout.md"]:
        expected_file = EXPECTED / rel
        if expected_file.exists():
            assert _read(out_dir / rel) == _read(expected_file), f"Golden mismatch: {rel}"


def test_ac608_blink_clk_top_port(tmp_path):
    """Verify the clock top port is named 'clk' (AC608 board convention)."""
    out_dir = tmp_path / "gen"
    result = FullBuildPipeline(templates_dir="socfw/templates").run(
        BuildRequest(project_file=str(FIXTURE), out_dir=str(out_dir))
    )
    assert result.ok
    sv = (out_dir / "rtl" / "soc_top.sv").read_text()
    assert "input wire clk" in sv


def test_ac608_blink_led_port_width(tmp_path):
    """Verify ONB_LEDS is 5-bit wide."""
    out_dir = tmp_path / "gen"
    result = FullBuildPipeline(templates_dir="socfw/templates").run(
        BuildRequest(project_file=str(FIXTURE), out_dir=str(out_dir))
    )
    assert result.ok
    sv = (out_dir / "rtl" / "soc_top.sv").read_text()
    assert "output wire [4:0] ONB_LEDS" in sv


def test_ac608_blink_device_part(tmp_path):
    """Verify the Quartus device assignment is EP4CE15E22C8."""
    out_dir = tmp_path / "gen"
    result = FullBuildPipeline(templates_dir="socfw/templates").run(
        BuildRequest(project_file=str(FIXTURE), out_dir=str(out_dir))
    )
    assert result.ok
    tcl = (out_dir / "hal" / "board.tcl").read_text()
    assert "set_global_assignment -name DEVICE EP4CE15E22C8" in tcl


def test_ac608_blink_led_pins(tmp_path):
    """Verify correct physical LED pin assignments."""
    out_dir = tmp_path / "gen"
    result = FullBuildPipeline(templates_dir="socfw/templates").run(
        BuildRequest(project_file=str(FIXTURE), out_dir=str(out_dir))
    )
    assert result.ok
    tcl = (out_dir / "hal" / "board.tcl").read_text()
    assert "set_location_assignment PIN_L3 -to ONB_LEDS[0]" in tcl
    assert "set_location_assignment PIN_F8 -to ONB_LEDS[4]" in tcl
