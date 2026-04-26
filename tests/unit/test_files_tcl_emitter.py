from pathlib import Path
from dataclasses import dataclass

from socfw.emit.files_tcl_emitter import FilesTclEmitter
from socfw.model.board import BoardClockDef, BoardResetDef, BoardModel
from socfw.model.ip import IpDescriptor, IpOrigin, IpArtifactBundle, IpResetSemantics, IpClocking, IpVendorInfo
from socfw.model.project import ProjectModel, ModuleInstance
from socfw.model.system import SystemModel


@dataclass(frozen=True)
class DummyBridge:
    rtl_file: str


def _make_system(*, bridge_file: str) -> SystemModel:
    board = BoardModel(
        board_id="demo",
        vendor=None,
        title=None,
        fpga_family="Cyclone IV E",
        fpga_part="EP4CE55",
        sys_clock=BoardClockDef(
            id="clk",
            top_name="SYS_CLK",
            pin="A1",
            frequency_hz=50_000_000,
        ),
        sys_reset=BoardResetDef(
            id="rst",
            top_name="RESET_N",
            pin="B1",
            active_low=True,
        ),
    )

    ip = IpDescriptor(
        name="clkpll",
        module="clkpll",
        category="clocking",
        origin=IpOrigin(kind="generated", packaging="quartus_ip"),
        needs_bus=False,
        generate_registers=False,
        instantiate_directly=True,
        dependency_only=False,
        reset=IpResetSemantics(),
        clocking=IpClocking(),
        artifacts=IpArtifactBundle(synthesis=("/tmp/clkpll.v", "/tmp/clkpll.qip")),
        vendor_info=IpVendorInfo(
            vendor="intel",
            tool="quartus",
            qip="/tmp/clkpll.qip",
            sdc=("/tmp/clkpll.sdc",),
        ),
    )

    project = ProjectModel(
        name="demo",
        mode="standalone",
        board_ref="demo",
        modules=[ModuleInstance(instance="pll0", type_name="clkpll")],
    )

    return SystemModel(
        board=board,
        project=project,
        timing=None,
        ip_catalog={"clkpll": ip},
    )


def test_files_tcl_emitter_writes_vendor_and_bridge_files(tmp_path):
    bridge_file = tmp_path / "bridge.sv"
    bridge_file.write_text("// bridge\n", encoding="utf-8")

    system = _make_system(bridge_file=str(bridge_file))

    out = FilesTclEmitter().emit(
        out_dir=str(tmp_path),
        system=system,
        planned_bridges=[DummyBridge(rtl_file=str(bridge_file))],
    )

    text = Path(out).read_text(encoding="utf-8")
    assert "VERILOG_FILE" in text and "clkpll.v" in text
    assert "bridge.sv" in text
    assert "QIP_FILE" in text and "clkpll.qip" in text
    assert "SDC_FILE" in text and "clkpll.sdc" in text
    assert Path(out).parent.name == "hal"
