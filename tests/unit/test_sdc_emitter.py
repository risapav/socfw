from pathlib import Path

from socfw.emit.sdc_emitter import SdcEmitter
from socfw.model.board import BoardClockDef, BoardResetDef, BoardModel
from socfw.model.project import ProjectModel
from socfw.model.system import SystemModel


def _make_system(*, freq_hz: int = 50_000_000, timing=None) -> SystemModel:
    board = BoardModel(
        board_id="demo",
        vendor=None,
        title=None,
        fpga_family="Cyclone IV E",
        fpga_part="EP4CE55",
        sys_clock=BoardClockDef(
            id="sys_clk",
            top_name="SYS_CLK",
            pin="A1",
            frequency_hz=freq_hz,
        ),
        sys_reset=BoardResetDef(
            id="rst",
            top_name="RESET_N",
            pin="B1",
            active_low=True,
        ),
    )
    project = ProjectModel(name="demo", mode="standalone", board_ref="demo")
    return SystemModel(board=board, project=project, timing=timing, ip_catalog={})


def test_sdc_emitter_writes_primary_clock(tmp_path):
    system = _make_system()

    out = SdcEmitter().emit(out_dir=str(tmp_path), system=system)
    text = Path(out).read_text(encoding="utf-8")

    assert "create_clock" in text
    assert "-period 20.000" in text
    assert "SYS_CLK" in text


def test_sdc_emitter_no_timing_model(tmp_path):
    system = _make_system(timing=None)
    out = SdcEmitter().emit(out_dir=str(tmp_path), system=system)
    text = Path(out).read_text(encoding="utf-8")
    assert "create_clock" in text
