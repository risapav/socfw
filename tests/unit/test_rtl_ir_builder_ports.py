from socfw.builders.rtl_ir_builder import RtlIrBuilder
from socfw.model.ip import IpDescriptor, IpOrigin, IpResetSemantics, IpClocking, IpArtifactBundle
from socfw.model.ports import PortDescriptor
from socfw.model.board import BoardModel, BoardClockDef, BoardResetDef, BoardResource, BoardVectorSignal
from socfw.model.project import ModuleInstance, ClockBinding, PortBinding, ProjectModel
from socfw.model.system import SystemModel


def _make_ip(ports):
    return IpDescriptor(
        name="demo",
        module="demo",
        category="standalone",
        origin=IpOrigin(kind="source"),
        needs_bus=False,
        generate_registers=False,
        instantiate_directly=True,
        dependency_only=False,
        reset=IpResetSemantics(),
        clocking=IpClocking(),
        artifacts=IpArtifactBundle(),
        ports=tuple(ports),
    )


def _make_system(ip, mod):
    board = BoardModel(
        board_id="demo",
        vendor=None,
        title=None,
        fpga_family="cyclone_iv",
        fpga_part="EP4CE55",
        sys_clock=BoardClockDef(id="sys_clk", top_name="SYS_CLK", pin="T8", frequency_hz=50_000_000),
        sys_reset=BoardResetDef(id="sys_rst", top_name="RESET_N", pin="N2", active_low=True),
        onboard={
            "leds": BoardResource(
                key="leds",
                kind="io",
                vectors={
                    "leds": BoardVectorSignal(
                        key="ONB_LEDS",
                        top_name="ONB_LEDS",
                        direction="output",
                        width=6,
                        pins={0: "A1", 1: "A2", 2: "A3", 3: "A4", 4: "A5", 5: "A6"},
                    )
                },
            )
        },
    )
    return SystemModel(
        board=board,
        project=ProjectModel(
            name="demo",
            mode="standalone",
            board_ref="demo",
            modules=[mod],
        ),
        timing=None,
        ip_catalog={ip.name: ip},
    )


def _conn_dict(top):
    inst = top.instances[0]
    return {c.port: c.expr for c in inst.connections}


def test_explicit_clock_binding_used():
    ip = _make_ip([
        PortDescriptor(name="clk", direction="input", width=1),
        PortDescriptor(name="out", direction="output", width=1),
    ])
    mod = ModuleInstance(
        instance="u_demo",
        type_name="demo",
        clocks=[ClockBinding(port_name="clk", domain="sys_clk")],
    )
    system = _make_system(ip, mod)
    top = RtlIrBuilder().build(system=system, planned_bridges=[])
    conns = _conn_dict(top)
    assert conns["clk"] == "SYS_CLK"


def test_unbound_input_gets_default_zero():
    ip = _make_ip([
        PortDescriptor(name="clk", direction="input", width=1),
        PortDescriptor(name="en", direction="input", width=1),
        PortDescriptor(name="data", direction="input", width=8),
    ])
    mod = ModuleInstance(
        instance="u_demo",
        type_name="demo",
        clocks=[ClockBinding(port_name="clk", domain="sys_clk")],
    )
    system = _make_system(ip, mod)
    top = RtlIrBuilder().build(system=system, planned_bridges=[])
    conns = _conn_dict(top)
    assert conns["en"] == "1'b0"
    assert conns["data"] == "8'h0"


def test_unbound_output_is_empty():
    ip = _make_ip([
        PortDescriptor(name="clk", direction="input", width=1),
        PortDescriptor(name="q", direction="output", width=4),
        PortDescriptor(name="z", direction="inout", width=16),
    ])
    mod = ModuleInstance(
        instance="u_demo",
        type_name="demo",
        clocks=[ClockBinding(port_name="clk", domain="sys_clk")],
    )
    system = _make_system(ip, mod)
    top = RtlIrBuilder().build(system=system, planned_bridges=[])
    conns = _conn_dict(top)
    assert conns["q"] == ""
    assert conns["z"] == ""


def test_board_binding_resolved_when_no_design():
    ip = _make_ip([
        PortDescriptor(name="SYS_CLK", direction="input", width=1),
        PortDescriptor(name="ONB_LEDS", direction="output", width=6),
    ])
    mod = ModuleInstance(
        instance="u_demo",
        type_name="demo",
        clocks=[ClockBinding(port_name="SYS_CLK", domain="sys_clk")],
        port_bindings=[PortBinding(port_name="ONB_LEDS", target="board:onboard.leds")],
    )
    system = _make_system(ip, mod)
    top = RtlIrBuilder().build(system=system, planned_bridges=[])
    conns = _conn_dict(top)
    assert conns["ONB_LEDS"] == "ONB_LEDS"


def test_fallback_to_explicit_when_no_ports():
    ip = _make_ip([])
    mod = ModuleInstance(
        instance="u_demo",
        type_name="demo",
        clocks=[ClockBinding(port_name="clk", domain="sys_clk")],
    )
    system = _make_system(ip, mod)
    top = RtlIrBuilder().build(system=system, planned_bridges=[])
    conns = _conn_dict(top)
    assert conns["clk"] == "SYS_CLK"
