from socfw.emit.rtl_emitter import RtlEmitter
from socfw.ir.rtl import RtlConnection, RtlInstance, RtlPort, RtlSignal, RtlTop


def test_rtl_emitter_writes_top(tmp_path):
    top = RtlTop(
        module_name="soc_top",
        instances=[
            RtlInstance(
                module="demo_mod",
                instance="u0",
                connections=(RtlConnection("clk", "1'b0"),),
            )
        ],
    )

    out = RtlEmitter().emit_top(str(tmp_path), top)
    text = (tmp_path / "rtl" / "soc_top.sv").read_text(encoding="utf-8")

    assert out.endswith("soc_top.sv")
    assert "module soc_top" in text
    assert "demo_mod u0" in text


def test_rtl_emitter_writes_top_with_ports(tmp_path):
    top = RtlTop(
        module_name="soc_top",
        ports=[RtlPort(direction="output", name="ONB_LEDS", width=6)],
        instances=[
            RtlInstance(
                module="demo_mod",
                instance="u0",
                connections=(RtlConnection("clk", "1'b0"),),
            )
        ],
    )

    RtlEmitter().emit_top(str(tmp_path), top)
    text = (tmp_path / "rtl" / "soc_top.sv").read_text(encoding="utf-8")

    assert "module soc_top (" in text
    assert "output wire [5:0] ONB_LEDS" in text
    assert "demo_mod u0" in text


def test_rtl_emitter_writes_top_with_ports_and_signals(tmp_path):
    top = RtlTop(
        module_name="soc_top",
        ports=[RtlPort(direction="output", name="ONB_LEDS", width=6)],
        signals=[RtlSignal(name="reset_n")],
        instances=[
            RtlInstance(
                module="demo_mod",
                instance="u0",
                connections=(RtlConnection("clk", "1'b0"),),
            )
        ],
    )

    RtlEmitter().emit_top(str(tmp_path), top)
    text = (tmp_path / "rtl" / "soc_top.sv").read_text(encoding="utf-8")

    assert "module soc_top (" in text
    assert "output wire [5:0] ONB_LEDS" in text
    assert "wire reset_n;" in text
    assert "demo_mod u0" in text
